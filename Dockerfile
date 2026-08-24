# ============================================================================
# RECONSTRUCTED FILE. The original Dockerfile was lost in the export of this
# course; this file was rebuilt from the README's own "Tested configuration"
# table and "Cluster image (Dockerfile)" subsection. It has NOT been built or
# tested. Every pinned version below comes from the README, not from a build
# log. Treat it as a starting point, not a verified image definition.
#
# Pins taken from the README:
#   Ray 2.53.0 / Python 3.11 / PyTorch 2.7.0 + CUDA 12.8 / Isaac Sim 5.1.0
#   Isaac Lab 0.54.4 (main@b0542fe, built from source)
#   lerobot 0.4.3 (--no-deps) / transformers @ dcddb97 (pinned commit)
#   numpy>=1.26,<2
#
# The base image tag below exists on Docker Hub, but whether it matches the
# original course image exactly is unconfirmed.
# ============================================================================

FROM anyscale/ray:2.53.0-py311-cu128

# --------------------------------------------------------------------------
# Build arguments.
# NV_DRIVER_VERSION must match the HOST driver, reported by:
#   nvidia-smi --query-gpu=driver_version --format=csv,noheader
# There is no safe default; pass it explicitly with --build-arg.
# ISAACLAB_COMMIT is the pinned Isaac Lab commit from the README (v0.54.4 era).
# --------------------------------------------------------------------------
ARG NV_DRIVER_VERSION
ARG ISAACLAB_COMMIT=b0542fe

USER root

# --------------------------------------------------------------------------
# NVIDIA graphics userspace (required, per the README).
# The container runtime injects only the COMPUTE driver libraries. Isaac Sim's
# Vulkan/RTX renderer also needs the GRAPHICS userspace libraries, so they are
# baked in here from the version-matched driver .run installer.
# The --no-kernel-modules install below is a best-effort reconstruction; the
# original library-selection details were lost with the original Dockerfile.
# --------------------------------------------------------------------------
RUN test -n "$NV_DRIVER_VERSION" || (echo "NV_DRIVER_VERSION build-arg is required" && false)
RUN apt-get update && apt-get install -y --no-install-recommends \
        kmod libvulkan1 vulkan-tools libglvnd0 libgl1 libglx0 libegl1 \
        libxext6 libx11-6 git wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN wget -q "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NV_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NV_DRIVER_VERSION}.run" \
        -O /tmp/nvidia-driver.run \
    && sh /tmp/nvidia-driver.run --silent --no-kernel-modules --no-nouveau-check \
        --no-questions --ui=none --install-libglvnd \
    && rm -f /tmp/nvidia-driver.run
# Vulkan ICD so the renderer finds the NVIDIA driver.
RUN mkdir -p /usr/share/vulkan/icd.d && printf '%s\n' \
    '{' \
    '    "file_format_version": "1.0.0",' \
    '    "ICD": {' \
    '        "library_path": "libGLX_nvidia.so.0",' \
    '        "api_version": "1.3.0"' \
    '    }' \
    '}' > /usr/share/vulkan/icd.d/nvidia_icd.json

USER ray

# --------------------------------------------------------------------------
# PyTorch pinned to the tested configuration (2.7.0 + CUDA 12.8).
# numpy is pinned <2 because Isaac Sim's compiled ABI breaks on numpy 2.
# --------------------------------------------------------------------------
RUN pip install --no-cache-dir "numpy>=1.26,<2" \
    && pip install --no-cache-dir "torch==2.7.0" \
        --index-url https://download.pytorch.org/whl/cu128

# --------------------------------------------------------------------------
# Isaac Sim 5.1.0 (pip distribution from NVIDIA's index).
# --------------------------------------------------------------------------
RUN pip install --no-cache-dir "isaacsim[all,extscache]==5.1.0" \
        --extra-index-url https://pypi.nvidia.com

# --------------------------------------------------------------------------
# Isaac Lab 0.54.4, built from source at the pinned commit so independent
# builds resolve to the same code instead of tracking a moving branch.
# --------------------------------------------------------------------------
RUN git clone https://github.com/isaac-sim/IsaacLab.git /home/ray/IsaacLab \
    && cd /home/ray/IsaacLab \
    && git checkout "${ISAACLAB_COMMIT}" \
    && ./isaaclab.sh --install none

# --------------------------------------------------------------------------
# Patched transformers fork, pinned to a commit. PI0.5's checkpoint stores
# Gemma layernorm parameters under a different key layout than mainline
# transformers >= 4.57, and PI05Pytorch.__init__ requires
# transformers.models.siglip.check, a symbol only in the fork.
# --------------------------------------------------------------------------
RUN pip install --no-cache-dir \
        "git+https://github.com/huggingface/transformers@dcddb97"

# --------------------------------------------------------------------------
# lerobot with --no-deps: its rerun-sdk dependency requires numpy>=2, which
# breaks Isaac Sim's compiled ABI. numpy stays pinned >=1.26,<2 above.
# wandb is installed only because lerobot expects it to be importable; the
# course reports metrics through Ray Train, not Weights & Biases.
# --------------------------------------------------------------------------
RUN pip install --no-cache-dir --no-deps "lerobot==0.4.3" \
    && pip install --no-cache-dir wandb av fsspec pillow

# --------------------------------------------------------------------------
# Runtime environment. The worker nodes have no C compiler, so dynamo falls
# back to eager cleanly. No Hugging Face token is needed; everything comes
# from the public S3 mirror, read unsigned.
# --------------------------------------------------------------------------
ENV TORCHDYNAMO_DISABLE=1 \
    HF_HUB_OFFLINE=1
