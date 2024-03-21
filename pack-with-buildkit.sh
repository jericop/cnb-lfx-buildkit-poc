#!/usr/bin/env bash

set -euo pipefail

repo_name="mybuildpack"
registry_name="local-registry"
builder_name="${registry_name}"

cleanup() {
  docker buildx stop "${builder_name}" > /dev/null 2>&1
  docker buildx rm "${builder_name}" > /dev/null 2>&1

  log_message "Stopping local registry"
  docker stop "${registry_name}" > /dev/null 2>&1
}

log_message() {
  echo "$1"
}

# https://github.com/docker/buildx/issues/166#issuecomment-1804970076
# First, we need to create our own buildx builder that uses the host nework and docker-container driver so that we can get multiarch support
log_message "Setting up docker buildx builder"
docker buildx use "${builder_name}" > /dev/null 2>&1 || docker buildx create --name "${builder_name}" --driver docker-container --driver-opt network=host --bootstrap --use > /dev/null 2>&1

# Next, we need to check if a registry is already running
log_message "Setting up a local registry on random port"
docker container inspect "${registry_name}" > /dev/null 2>&1 || docker run -d -e REGISTRY_STORAGE_DELETE_ENABLED=true -p 0:5000 --rm --name "${registry_name}" registry:2 > /dev/null 2>&1

# Get local registry port since we asked docker to assign a random port by choosing port 0
registry_port=$(docker inspect "${registry_name}" | jq -r '.[0].NetworkSettings.Ports["5000/tcp"][0].HostPort')
log_message "Local registry is listening on port ${registry_port}"

# Rather than creating the necessary files manually, we let pack generate and the inline buildpack 
# copy them to /layers/build-files we publish to a local registry so we can capture 
pack build localhost:$registry_port/inline-app \
  --publish --verbose --network host 2>&1 | tee pack-build.log \
  | grep -B3 -A4 "Args: '/cnb/lifecycle" > lifecycle-commands.log

docker pull localhost:$registry_port/inline-app

if [ -d cnb-build-files ]; then
  rm -rf cnb-build-files
fi
mkdir -p cnb-build-files

# Copy the files created by pack during the build from the volume and into the local directory 
docker run --rm --entrypoint bash --user root \
  --volume $(pwd)/cnb-build-files:/hostmnt \
  localhost:$registry_port/inline-app \
  -c 'cp -R /workspace/build-files/* /hostmnt/'

# We copy the initial Dockerfile (without lifecycle commands) to Dockerfile
cp Dockerfile-initial Dockerfile

# Then we add a run command (heredoc) with the lifecycle commands to build and push the architecture-specific images
cat <<ADD_RUN_COMMAND_TO_DOCKERFILE_EOF >> Dockerfile 
RUN <<RUN_EOF

export image_arch=amd64
if [ \$(arch) = "aarch64" ]; then
  export image_arch=arm64
fi

export image_uri="localhost:$registry_port/inline-app:\$image_arch"

echo "#!/bin/bash" > /workspace/lifecycle-build.sh
cat <<IN_BUILDKIT_LIFECYCLE_SCRIPT_EOF >> /workspace/lifecycle-build.sh

set -euo pipefail
set -x

ADD_RUN_COMMAND_TO_DOCKERFILE_EOF

# Add the lifecycle commands from the saved log output of `pack build` we ran above
while read cmd; do
  if echo $cmd | grep -q "localhost:$registry_port/inline-app\$"; then
    echo "$cmd:\$image_arch" >> Dockerfile
  else
    echo "$cmd" >> Dockerfile
  fi
done < <(grep Args: lifecycle-commands.log | cut -d"'" -f2)

cat <<'CONTINUE_ADD_RUN_COMMAND_TO_DOCKERFILE_EOF' >> Dockerfile

crane pull $image_uri image.tar

mkdir -p contents
tar -xvf image.tar -C contents
cd contents
ls
cat manifest.json | jq -r '.[0].Config'
current_config=\$(cat manifest.json | jq -r '.[0].Config')
echo \$current_config
cat \$current_config | jq -c ".architecture = \"\${image_arch}\" | .os = \"linux\"" | tr -d '\n' > newconfig.json
new_config="sha256:$(sha256sum newconfig.json | cut -d' ' -f1)"
rm -f "\${current_config}"
mv newconfig.json "\${new_config}"
cat manifest.json| jq -c ".[0].Config = \"\${new_config}\"" | tr -d '\n' > newmanifest.json
mv -f newmanifest.json manifest.json
tar -cvf ../fixed-arch-image.tar *
cd ..

crane push fixed-arch-image.tar $image_uri

rm -rf image.tar fixed-arch-image.tar contents

IN_BUILDKIT_LIFECYCLE_SCRIPT_EOF

# Run the lifecycle script and ensure correct architecture is set
chmod +x /workspace/lifecycle-build.sh
/workspace/lifecycle-build.sh

RUN_EOF

CONTINUE_ADD_RUN_COMMAND_TO_DOCKERFILE_EOF

# After all of that, we are finally ready to build the multi-arch images using the lifecycle with buildkit.
# We are not publishing with this command because the lifecyle will publish the images to the local registry for us.
docker buildx build --tag ignored --platform linux/amd64,linux/arm64 .

# Now we can combine the linux/amd64 and linux/arm64 images into a manifest list and push it to the local registry
docker buildx imagetools create \
  --tag localhost:$registry_port/inline-app:latest \
  localhost:$registry_port/inline-app:amd64 \
  localhost:$registry_port/inline-app:arm64

crane manifest localhost:$registry_port/inline-app:latest  | jq

if [[ ! -z "${PUBLISH_TO_GHCR_IO_IMAGE_URI:-}" ]]; then
  crane copy localhost:$registry_port/inline-app:latest ghcr.io/jericop/inline-app:latest
  log_message "Published image to: $PUBLISH_TO_GHCR_IO_IMAGE_URI"
fi

# This image can then be copied to another registry
