#!/bin/bash
set -exo pipefail

echo "
###########################################
# BEGIN: ComputeNode Enroot & Pyxis Setup
# Storage Layout:
#   /fsx     - FSx OpenZFS (공유 코드/이미지)
#   /lustre  - FSx Lustre (고속 데이터)
#   /scratch - NVMe (로컬 캐시, 최고속)
###########################################
"

# ============================================
# Enroot 디렉토리 설정
# ============================================

# ============================================
# tmpfiles.d로 /run 디렉토리 영구 설정
# ============================================
echo "Configuring tmpfiles.d for persistent /run directories..."

cat > /etc/tmpfiles.d/enroot.conf << 'EOF'
# Enroot and Pyxis runtime directories
# Type Path              Mode UID  GID  Age Argument
d      /run/enroot       1777 root root -   -
d      /run/pyxis        1777 root root -   -
EOF

# 즉시 적용
systemd-tmpfiles --create /etc/tmpfiles.d/enroot.conf

echo "✓ tmpfiles.d configured"

# 휘발성 런타임 - 로컬 tmpfs
ENROOT_RUNTIME_DIR="/run/enroot"
mkdir -p ${ENROOT_RUNTIME_DIR}
chmod 1777 ${ENROOT_RUNTIME_DIR}

echo "✓ Created Enroot runtime directory: ${ENROOT_RUNTIME_DIR}"

# /scratch를 캐시로 사용 (NVMe - 매우 빠름)
if [ -d /scratch ]; then
    mkdir -p /scratch/enroot-cache
    mkdir -p /scratch/enroot-data
    chmod 1777 /scratch/enroot-cache
    chmod 1777 /scratch/enroot-data
    CACHE_PATH="/scratch/enroot-cache-\$(id -u)"
    DATA_PATH="/scratch/enroot-data-\$(id -u)"
    echo "✓ Using /scratch for Enroot cache and data (NVMe)"
else
    mkdir -p /tmp/enroot-cache
    mkdir -p /tmp/enroot-data
    chmod 1777 /tmp/enroot-cache
    chmod 1777 /tmp/enroot-data
    CACHE_PATH="/tmp/enroot-cache-\$(id -u)"
    DATA_PATH="/tmp/enroot-data-\$(id -u)"
    echo "⚠ /scratch not found, using /tmp for cache and data"
fi

# ============================================
# Enroot 설정 파일
# ============================================

if [ -f /opt/parallelcluster/examples/enroot/enroot.conf ]; then
    echo "Found ParallelCluster Enroot example config"
    cp /opt/parallelcluster/examples/enroot/enroot.conf /etc/enroot/enroot.conf.bak
fi

cat > /etc/enroot/enroot.conf << EOF
# 런타임 경로 - 로컬 tmpfs (최고 속도)
ENROOT_RUNTIME_PATH /run/enroot/user-\$(id -u)

# 캐시 경로 - NVMe scratch (매우 빠름) 또는 /tmp
ENROOT_CACHE_PATH ${CACHE_PATH}

# 데이터 경로 - NVMe scratch (매우 빠름, 노드별 독립)
# 중요: 공유 스토리지 사용 안 함 (충돌 방지)
ENROOT_DATA_PATH ${DATA_PATH}

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

# Enroot hooks
if [ -f /usr/share/enroot/hooks.d/50-slurm-pmi.sh ]; then
    ln -sf /usr/share/enroot/hooks.d/50-slurm-pmi.sh /etc/enroot/hooks.d/ 2>/dev/null || true
    echo "✓ Linked Enroot Slurm PMI hook"
fi

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
# GPU 기본 설정
# ============================================

if command -v nvidia-smi &> /dev/null; then
    nvidia-smi -pm 1
    echo "✓ GPU persistence mode enabled"
else
    echo "⚠ nvidia-smi not found (GPU drivers may not be loaded yet)"
fi

# ============================================
# 환경 변수 설정
# ============================================

cat > /etc/profile.d/cluster-storage.sh << 'EOF'
# ===========================================
# Cluster Storage Environment Variables
# ===========================================

# FSx OpenZFS (/fsx) - 공유 코드 및 컨테이너
export CONTAINER_IMAGES_DIR=/fsx/containers/images
export CODE_DIR=/fsx/code
export CONFIG_DIR=/fsx/configs
export MODELS_DIR=/fsx/models

# FSx Lustre (/lustre) - 고속 학습 데이터
export DATA_DIR=/lustre/data
export CHECKPOINT_DIR=/lustre/checkpoints
export LOG_DIR=/lustre/logs
export RESULTS_DIR=/lustre/results
EOF

# /scratch 사용 여부에 따라 캐시/데이터 경로 설정
if [ -d /scratch ]; then
    cat >> /etc/profile.d/cluster-storage.sh << 'EOF'

# Enroot 설정 (NVMe scratch)
export ENROOT_CACHE_PATH=/scratch/enroot-cache-$(id -u)
export ENROOT_DATA_PATH=/scratch/enroot-data-$(id -u)
EOF
else
    cat >> /etc/profile.d/cluster-storage.sh << 'EOF'

# Enroot 설정 (local /tmp)
export ENROOT_CACHE_PATH=/tmp/enroot-cache-$(id -u)
export ENROOT_DATA_PATH=/tmp/enroot-data-$(id -u)
EOF
fi

chmod 644 /etc/profile.d/cluster-storage.sh

echo "✓ Created environment variables"

# ============================================
# 정리 스크립트 생성
# ============================================

cat > /usr/local/bin/cleanup-enroot << 'EOF'
#!/bin/bash
# Enroot 임시 파일 정리 스크립트

echo "Cleaning up Enroot temporary files on ComputeNode..."

# 로컬 정리
rm -rf /tmp/enroot-data-* 2>/dev/null || true
rm -rf /tmp/enroot-cache-* 2>/dev/null || true

# NVMe scratch 정리
if [ -d /scratch ]; then
    rm -rf /scratch/enroot-data-* 2>/dev/null || true
    rm -rf /scratch/enroot-cache-* 2>/dev/null || true
fi

echo "✓ Cleanup completed"
EOF

chmod +x /usr/local/bin/cleanup-enroot

echo "✓ Created cleanup script: /usr/local/bin/cleanup-enroot"

# ============================================
# 완료 메시지
# ============================================

CACHE_LOCATION="/scratch"
[ ! -d /scratch ] && CACHE_LOCATION="/tmp"

echo "
###########################################
# ComputeNode Setup Complete!
###########################################

Storage Layout:
  /fsx/containers/images/    - 컨테이너 이미지 (read) [공유]
  /fsx/code/                 - 학습 코드 (read) [공유]
  
  /lustre/data/              - 학습 데이터 (read, 고속) [공유]
  /lustre/checkpoints/       - 체크포인트 (write, 고속) [공유]
  
  ${CACHE_LOCATION}/enroot-cache/     - Enroot 캐시 (빠름) [노드별]
  ${CACHE_LOCATION}/enroot-data/      - Enroot 데이터 (빠름) [노드별]

Enroot Configuration:
  Runtime:  /run/enroot/               (tmpfs, 최고속)
  Cache:    ${CACHE_LOCATION}/enroot-cache-<uid>/   (local, 빠름)
  Data:     ${CACHE_LOCATION}/enroot-data-<uid>/    (local, 충돌 방지)

Helper Scripts:
  /usr/local/bin/cleanup-enroot     - Clean temporary files

###########################################
"