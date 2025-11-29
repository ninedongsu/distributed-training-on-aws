#!/bin/bash
set -exo pipefail

echo "
###########################################
# BEGIN: HeadNode Enroot & Pyxis Setup
# Storage Layout:
#   /fsx     - FSx OpenZFS (공유 코드/이미지)
#   /lustre  - FSx Lustre (고속 데이터)
#   /tmp     - 로컬 임시 (Enroot 데이터)
###########################################
"

# ============================================
# Enroot 디렉토리 설정
# ============================================

# 휘발성 런타임 - 로컬 tmpfs
ENROOT_RUNTIME_DIR="/run/enroot"
mkdir -p ${ENROOT_RUNTIME_DIR}
chmod 1777 ${ENROOT_RUNTIME_DIR}

echo "✓ Created Enroot runtime directory: ${ENROOT_RUNTIME_DIR}"

# 로컬 임시 디렉토리
mkdir -p /tmp/enroot-cache
chmod 1777 /tmp/enroot-cache

mkdir -p /tmp/enroot-data
chmod 1777 /tmp/enroot-data

echo "✓ Created local Enroot directories"

# ============================================
# Enroot 설정 파일
# ============================================

if [ -f /opt/parallelcluster/examples/enroot/enroot.conf ]; then
    echo "Found ParallelCluster Enroot example config"
    cp /opt/parallelcluster/examples/enroot/enroot.conf /etc/enroot/enroot.conf.bak
fi

cat > /etc/enroot/enroot.conf << 'EOF'
# 런타임 경로 - 로컬 tmpfs (최고속)
ENROOT_RUNTIME_PATH /run/enroot/user-$(id -u)

# 캐시 경로 - 로컬 /tmp (노드별 독립)
ENROOT_CACHE_PATH /tmp/enroot-cache-$(id -u)

# 데이터 경로 - 로컬 /tmp (공유 스토리지 X, 충돌 방지)
ENROOT_DATA_PATH /tmp/enroot-data-$(id -u)

# 임시 파일 경로
ENROOT_TEMP_PATH /tmp

# Squashfs 압축 옵션
ENROOT_SQUASH_OPTIONS -comp lzo -noD

# 마운트 설정
ENROOT_MOUNT_HOME yes
ENROOT_RESTRICT_DEV yes
ENROOT_ROOTFS_WRITABLE no
EOF

chmod 0644 /etc/enroot/enroot.conf

echo "✓ Created Enroot configuration"
cat /etc/enroot/enroot.conf

# ============================================
# Pyxis 디렉토리 설정
# ============================================

PYXIS_RUNTIME_DIR="/run/pyxis"
mkdir -p ${PYXIS_RUNTIME_DIR}
chmod 1777 ${PYXIS_RUNTIME_DIR}

echo "✓ Created Pyxis runtime directory: ${PYXIS_RUNTIME_DIR}"

# ============================================
# Slurm Plugstack 설정
# ============================================

mkdir -p /opt/slurm/etc/plugstack.conf.d/

# ParallelCluster 예제 사용
if [ -f /opt/parallelcluster/examples/spank/plugstack.conf ]; then
    cp /opt/parallelcluster/examples/spank/plugstack.conf /opt/slurm/etc/
    echo "✓ Copied plugstack.conf from ParallelCluster examples"
else
    cat > /opt/slurm/etc/plugstack.conf << 'EOF'
include /opt/slurm/etc/plugstack.conf.d/*.conf
EOF
    echo "✓ Created new plugstack.conf"
fi

if [ -f /opt/parallelcluster/examples/pyxis/pyxis.conf ]; then
    cp /opt/parallelcluster/examples/pyxis/pyxis.conf /opt/slurm/etc/plugstack.conf.d/
    echo "✓ Copied pyxis.conf from ParallelCluster examples"
else
    cat > /opt/slurm/etc/plugstack.conf.d/pyxis.conf << 'EOF'
required /usr/local/lib/slurm/spank_pyxis.so
EOF
    echo "✓ Created new pyxis.conf"
fi

# ============================================
# 스토리지 디렉토리 구조 생성
# ============================================

echo "Creating storage directory structure..."

# /fsx (FSx OpenZFS) - 공유 코드, 컨테이너 이미지
mkdir -p /fsx/containers/images
mkdir -p /fsx/containers/cache
mkdir -p /fsx/code
mkdir -p /fsx/configs
mkdir -p /fsx/models
mkdir -p /fsx/jobs

chmod 775 /fsx/containers/images
chmod 1777 /fsx/containers/cache
chmod 775 /fsx/code
chmod 775 /fsx/configs
chmod 775 /fsx/models
chmod 775 /fsx/jobs

echo "✓ Created /fsx directory structure (FSx OpenZFS)"

# /lustre (FSx Lustre) - 고속 학습 데이터
mkdir -p /lustre/data
mkdir -p /lustre/checkpoints
mkdir -p /lustre/logs
mkdir -p /lustre/results

chmod 775 /lustre/data
chmod 775 /lustre/checkpoints
chmod 775 /lustre/logs
chmod 775 /lustre/results

echo "✓ Created /lustre directory structure (FSx Lustre)"

# ============================================
# 환경 변수 설정
# ============================================

cat > /etc/profile.d/cluster-storage.sh << 'EOF'
# ===========================================
# Cluster Storage Environment Variables
# ===========================================

# FSx OpenZFS (/fsx) - 공유 코드 및 컨테이너
export CONTAINER_IMAGES_DIR=/fsx/containers/images
export CONTAINER_CACHE_DIR=/fsx/containers/cache
export CODE_DIR=/fsx/code
export CONFIG_DIR=/fsx/configs
export MODELS_DIR=/fsx/models
export JOBS_DIR=/fsx/jobs

# FSx Lustre (/lustre) - 고속 학습 데이터
export DATA_DIR=/lustre/data
export CHECKPOINT_DIR=/lustre/checkpoints
export LOG_DIR=/lustre/logs
export RESULTS_DIR=/lustre/results

# Enroot 기본 설정 (로컬 스토리지 사용)
export ENROOT_CACHE_PATH=/tmp/enroot-cache-$(id -u)
export ENROOT_DATA_PATH=/tmp/enroot-data-$(id -u)
EOF

chmod 644 /etc/profile.d/cluster-storage.sh

echo "✓ Created environment variables"

# ============================================
# 헬퍼 스크립트 생성
# ============================================

cat > /fsx/import-container.sh << 'EOF'
#!/bin/bash
# Enroot 컨테이너 이미지 import 헬퍼 스크립트

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <docker-image-url> [output-name]"
    echo ""
    echo "Examples:"
    echo "  $0 nvcr.io/nvidia/pytorch:24.01-py3"
    echo "  $0 763104351884.dkr.ecr.us-east-1.amazonaws.com/pytorch-training:2.1-gpu-py310 pytorch-dlc"
    echo ""
    echo "Storage locations:"
    echo "  Images: /fsx/containers/images/"
    echo "  Cache:  /fsx/containers/cache/"
    exit 1
fi

IMAGE_URL=$1
OUTPUT_NAME=$2

# Enroot 환경 변수 설정 (import 시에는 공유 스토리지 사용)
export ENROOT_CACHE_PATH=/fsx/containers/cache
export ENROOT_DATA_PATH=/fsx/containers/images

cd /fsx/containers/images

echo "Importing container image..."
echo "Source: ${IMAGE_URL}"

if [ -z "$OUTPUT_NAME" ]; then
    enroot import "dockerd://${IMAGE_URL}"
else
    echo "Output: ${OUTPUT_NAME}.sqsh"
    enroot import --output "${OUTPUT_NAME}.sqsh" "dockerd://${IMAGE_URL}"
fi

echo ""
echo "✓ Import completed!"
echo ""
echo "Available container images:"
ls -lh /fsx/containers/images/*.sqsh 2>/dev/null || echo "  (no images yet)"
EOF

chmod +x /fsx/import-container.sh

echo "✓ Created container import helper script: /fsx/import-container.sh"

# ============================================
# 정리 스크립트 생성
# ============================================

cat > /usr/local/bin/cleanup-enroot << 'EOF'
#!/bin/bash
# Enroot 임시 파일 정리 스크립트

echo "Cleaning up Enroot temporary files..."

# 로컬 정리
rm -rf /tmp/enroot-data-* 2>/dev/null || true
rm -rf /tmp/enroot-cache-* 2>/dev/null || true

# 공유 캐시 정리 (선택적)
if [ "$1" == "--all" ]; then
    echo "Cleaning shared cache..."
    rm -rf /fsx/containers/cache/* 2>/dev/null || true
fi

echo "✓ Cleanup completed"
EOF

chmod +x /usr/local/bin/cleanup-enroot

echo "✓ Created cleanup script: /usr/local/bin/cleanup-enroot"

# ============================================
# Slurm 재설정
# ============================================

sudo -i scontrol reconfigure

# ============================================
# 완료 메시지
# ============================================

echo "
###########################################
# HeadNode Setup Complete!
###########################################

Storage Layout:
  /fsx/containers/images/    - 컨테이너 이미지 (.sqsh 파일) [공유]
  /fsx/code/                 - 학습 코드 [공유]
  /fsx/configs/              - 설정 파일 [공유]
  /fsx/jobs/                 - 작업 스크립트 [공유]
  
  /lustre/data/              - 학습 데이터 (고속) [공유]
  /lustre/checkpoints/       - 체크포인트 (고속) [공유]
  /lustre/logs/              - 로그 파일 [공유]

Enroot Configuration:
  Runtime:  /run/enroot/            (tmpfs, 최고속)
  Cache:    /tmp/enroot-cache/      (local, 노드별)
  Data:     /tmp/enroot-data/       (local, 노드별, 충돌 방지)

Helper Scripts:
  /fsx/import-container.sh          - Import Docker images
  /usr/local/bin/cleanup-enroot     - Clean temporary files

Next Steps:
  1. Import a container image:
     /fsx/import-container.sh nvcr.io/nvidia/pytorch:24.01-py3
  
  2. Upload training code to:
     /fsx/code/
  
  3. Upload training data to:
     /lustre/data/
  
  4. Clean up if needed:
     cleanup-enroot [--all]

###########################################
"