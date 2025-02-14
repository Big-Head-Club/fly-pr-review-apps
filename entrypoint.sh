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

# Step 1: Get all environment variables from the VM
echo "Getting environment variables from VM..."
all_env=$(flyctl ssh console -a mop-activity-server -C "printenv")
echo "All environment variables retrieved:"
echo "$all_env"

# Step 2: Filter for the secrets we care about
echo "Filtering for relevant secrets..."
filtered_secrets=$(echo "$all_env" | grep -E '^(ACTIVITY_|AWS_|DATABASE_|DISCORD_|VITE_)')
echo "Filtered secrets:"
echo "$filtered_secrets"

# Step 3: Format into space-separated string for secrets command
secrets_string=$(echo "$filtered_secrets" | tr '\n' ' ')
echo "Formatted secrets string length: ${#secrets_string}"

if [ -n "$secrets_string" ]; then
  echo "Setting secrets..."
  echo "Will execute: flyctl secrets set -a $app [REDACTED]"
  flyctl secrets set -a "$app" $secrets_string --detach
else
  echo "No secrets found to copy"
fi

# Add a NODE_ENV variable to the secrets string with 'development'
secrets_string="$secrets_string NODE_ENV=development"

# Add a PRODUCTION environment variable to the secrets string with 'false'
secrets_string="$secrets_string PRODUCTION=false"

# Those two things should get the websockets working

# Remove the VITE_API_URL variable and its value from the secrets string
secrets_string=$(echo "$secrets_string" | sed '/VITE_API_URL=/d')

# Override the VITE_API_URL variable in the secrets string to 'https://mop-pr-<PR_NUMBER>.fly.dev'
secrets_string="$secrets_string VITE_API_URL=https://mop-pr-$PR_NUMBER.fly.dev"

# Attach postgres cluster to the app if specified.
if [ -n "$INPUT_POSTGRES" ]; then
  flyctl postgres attach "$INPUT_POSTGRES" --app "$app" || true
fi

# Trigger the deploy of the new version.
echo "Contents of config $config file: " && cat "$config"
if [ -n "$INPUT_VM" ]; then
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-size "$INPUT_VMSIZE" --dockerfile activity-server.Dockerfile --build-arg VITE_API_URL=https://mop-pr-$PR_NUMBER.fly.dev --build-arg VITE_SHOULD_PROXY_S3=false --build-arg VITE_USE_DUMMY_DATA="$vite_use_dummy_data" --build-arg NODE_ENV=development
else
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA --vm-cpu-kind "$INPUT_CPUKIND" --vm-cpus $INPUT_CPU --vm-memory "$INPUT_MEMORY" --dockerfile activity-server.Dockerfile --build-arg VITE_API_URL=https://mop-pr-$PR_NUMBER.fly.dev --build-arg VITE_SHOULD_PROXY_S3=false --build-arg VITE_USE_DUMMY_DATA="$vite_use_dummy_data" --build-arg NODE_ENV=development
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT
