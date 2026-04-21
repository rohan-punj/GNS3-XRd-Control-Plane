# syntax=docker/dockerfile:1
#
# Custom Cisco XRd Control Plane image for GNS3
# ---------------------------------------------
# Bakes a default first-boot config into the image so that GNS3 nodes come up
# with a pre-configured admin user and any other bootstrap config you need.
#
# Build:
#   # 1. Load the official XRd image first:
#   docker load -i xrd-control-plane-<version>.tar.gz
#
#   # 2. Confirm the tag (e.g. ios-xr/xrd-control-plane:24.4.1):
#   docker images | grep xrd
#
#   # 3. Build this custom image, passing the base tag as a build arg:
#   docker build \
#     --build-arg BASE_IMAGE=ios-xr/xrd-control-plane:24.4.1 \
#     -t xrd-cp-gns3:latest .
#
#   # 4. The .gns3a appliance references 'xrd-cp-gns3:latest' — just import it
#      and GNS3 will pick up this image automatically.
# ---------------------------------------------

ARG BASE_IMAGE=ios-xr/xrd-control-plane:latest
FROM ${BASE_IMAGE}

# Copy the first-boot config into the container at the path referenced by
# the XR_FIRST_BOOT_CONFIG environment variable (set in the GNS3 template).
COPY firstboot.cfg /firstboot.cfg

# Metadata
LABEL maintainer="GNS3 XRd Lab" \
      description="Cisco XRd Control Plane pre-loaded with GNS3 first-boot config" \
      source="Adapted from XRd docs"

# Do NOT override CMD/ENTRYPOINT — XRd's default launcher must run.
