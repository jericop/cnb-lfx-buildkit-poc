# cnb-lfx-buildkit-poc

This repo is an initial proof-of-concept for the following LFX mentorship project.

[CNCF - Cloud Native Buildpacks: Proof of concept making multiarch images with buildkit (2024 Term 1)](https://mentorship.lfx.linuxfoundation.org/project/2c5ced86-d23b-41f5-aec3-59730e29f092)

It is heavliy inspired by the following article. While the article is invaluable for understanding how the lifecycle works, it requires a fair amount of manual steps, which must be repeated if any changes are made to buildpacks. For the sake of simplicity, I am using an inline buildpack and running `pack build` once in order to copy out the necessary files.

* https://medium.com/buildpacks/unpacking-cloud-native-buildpacks-ff51b5a767bf

## Primary objective

The primary objective is to create a Dockerfile that has all of the lifecycle commands needed to build and push architecture-specific images to a registry. `Dockerfile-example` is an example of how it works. You can then combine the architecture-specific images into a manifest list (multi-arch) image.

## `pack-with-buildkit.sh`

This script will do the following:

* Sets up a buildkit builder with `host` network access
* Starts a local registry on a random port
* Run `pack build` using the `project.toml` which has an inline buildpack that copies the files we need to /workspace
* Copies the files we need out of the container built with pack so we can use them in a new build (with buildkit)
* Generates a `Dockerfile` from `Dockerfile-initial` that will look like `Dockerfile-example`
* Runs `docker buildx build --platform linux/amd64,linux/arm64` to execute the lifecycle commands through buildkit
  * This builds and publishes images to the local registry with `amd64` and `arm64` tags
  * There is some hackery that happens to fix the architecture (for now)
* Finally it creates a manifest list with the `amd64` and `arm64` tagged images

## Requirements

* Multi-arch builders are required. I'm using ones that I build and publish.

## Published image(s)

* ghcr.io/jericop/inline-app:latest