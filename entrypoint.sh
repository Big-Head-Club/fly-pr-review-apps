#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

GITHUB_REPOSITORY_NAME=${GITHUB_REPOSITORY#$GITHUB_REPOSITORY_OWNER/}
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$GITHUB_REPOSITORY_OWNER-$GITHUB_REPOSITORY_NAME}"
# Change underscores to hyphens.
app="${app//_/-}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"

# vite_api_url="$INPUT_VITE_API_URL"
# vite_should_proxy_s3="$INPUT_VITE_SHOULD_PROXY_S3"
vite_use_dummy_data="$INPUT_VITE_USE_DUMMY_DATA"
node_env="$INPUT_NODE_ENV"

# echo "vite_api_url=$vite_api_url"
# echo "vite_should_proxy_s3=$vite_should_proxy_s3"
echo "vite_use_dummy_data=$vite_use_dummy_data"
echo "node_env=$node_env"

# Error out if any of the variables are empty
if [ -z "$vite_use_dummy_data" ] || [ -z "$node_env" ]; then
  echo "Error: One or more variables are empty. Please check your environment variables."
  exit 1
fi

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  exit 0
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  # Backup the original config file since 'flyctl launch' messes up the [build.args] section
  cp "$config" "$config.bak"
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --region "$region" --org "$org" $INPUT_LAUNCH_OPTIONS
  # Restore the original config file
  cp "$config.bak" "$config"
fi
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
fi

# Copy secrets from the main app to the PR app
echo "Copying secrets from mop-activity-server to $app"

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Get list of secret names first
echo "Getting secret names..."
flyctl secrets list -a mop-activity-server | awk '/=/ {print $1}' > secret_names.txt

# Create a temporary script to read the secrets
cat > read_secrets.sh << 'EOF'
#!/bin/sh
while IFS= read -r secret_name; do
  val=$(printenv "$secret_name")
  if [ -n "$val" ]; then
    echo "$secret_name=$val"
  fi
done < secret_names.txt
EOF

echo "Copying files to VM..."
# First ensure we can connect to a VM
if ! flyctl ssh console -a mop-activity-server -C "pwd"; then
  echo "Failed to connect to VM"
  exit 1
fi

# Copy and execute files one at a time
flyctl ssh console -a mop-activity-server -C "mkdir -p /tmp/secrets"
flyctl ssh console -a mop-activity-server -C "cat /tmp/secrets/secret_names.txt" > secret_names.txt
flyctl ssh console -a mop-activity-server -C "cat /tmp/secrets/read_secrets.sh" > read_secrets.sh
flyctl ssh console -a mop-activity-server -C "chmod +x /tmp/secrets/read_secrets.sh && cd /tmp/secrets && ./read_secrets.sh" > secrets_with_values.txt

# Format and set the secrets
if [ -s secrets_with_values.txt ]; then
  echo "Setting secrets..."
  secrets_string=$(cat secrets_with_values.txt | tr '\n' ' ')
  echo "Will execute: flyctl secrets set -a $app [REDACTED]"
  flyctl secrets set -a "$app" $secrets_string --detach
else
  echo "No secrets found to copy"
fi

# Clean up
cd -
rm -rf "$TEMP_DIR"

# Attach postgres cluster to the app if specified.
if [ -n "$INPUT_POSTGRES" ]; then
  flyctl postgres attach "$INPUT_POSTGRES" --app "$app" || true
fi

# Trigger the deploy of the new version.
echo "Contents of config $config file: " && cat "$config"
if [ -n "$INPUT_VM" ]; then
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-size "$INPUT_VMSIZE" --dockerfile activity-server.Dockerfile --build-arg VITE_API_URL="" --build-arg VITE_SHOULD_PROXY_S3=false --build-arg VITE_USE_DUMMY_DATA="$vite_use_dummy_data" --build-arg NODE_ENV="$node_env"
else
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-cpu-kind "$INPUT_CPUKIND" --vm-cpus $INPUT_CPU --vm-memory "$INPUT_MEMORY" --dockerfile activity-server.Dockerfile --build-arg VITE_API_URL="" --build-arg VITE_SHOULD_PROXY_S3=false --build-arg VITE_USE_DUMMY_DATA="$vite_use_dummy_data" --build-arg NODE_ENV="$node_env"
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT
