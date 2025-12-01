# 4. NCCL Tests 실행

> 💡 **목표:** 컨테이너 기반 분산 학습 작업을 Slurm으로 실행합니다.

## 목차

- [개요](#개요)
- [NCCL Tests 이해](#nccl-tests-이해)
- [4.1 테스트 환경 준비](#41-테스트-환경-준비)
  - [4.1.1 NCCL 컨테이너 이미지 준비](#411-nccl-컨테이너-이미지-준비)
  - [4.1.2 테스트 스크립트 작성](#412-테스트-스크립트-작성)
- [4.2 다중 노드 테스트](#42-다중-노드-테스트)
  - [4.2.1 노드 간 통신 테스트](#421-노드-간-통신-테스트)
  - [4.2.2 대역폭 측정](#422-대역폭-측정)
  - [4.2.3 지연시간 측정](#423-지연시간-측정)
- [다음 단계](#다음-단계)

---

## 개요

NCCL (NVIDIA Collective Communications Library) Tests는 GPU 클러스터의 통신 성능을 측정하는 도구입니다.
분산 학습 작업을 시작하기 전에 네트워크 인프라가 올바르게 구성되었는지 확인하는 것이 중요합니다.

**이 섹션에서 수행할 작업:**
- NCCL Tests 컨테이너 환경 구성
- 다중 노드 GPU 통신 성능 측정

** 해당 가이드는 p5e.48xlarge 2대를 기준으로 작성 되었습니다. **

---

## NCCL Tests 이해

### 주요 테스트 항목

| 테스트 유형 | 설명 | 용도 |
|----------|------|------|
| **all_reduce_perf** | 모든 GPU에서 데이터를 집계하고 결과를 분산 | 가장 일반적인 분산 학습 연산 |
| **all_gather_perf** | 모든 GPU의 데이터를 수집 | 그래디언트 수집 시뮬레이션 |
| **broadcast_perf** | 하나의 GPU에서 모든 GPU로 데이터 전송 | 모델 파라미터 동기화 |
| **reduce_scatter_perf** | 데이터를 집계하고 분산 | 효율적인 그래디언트 분산 |

### 측정 지표

- **Bus Bandwidth (busbw)**: 실제 사용 가능한 대역폭
- **Algorithm Bandwidth (algbw)**: 알고리즘 효율성을 고려한 대역폭
- **Latency**: 통신 지연시간

---

## 4.1 테스트 환경 준비

### 4.1.1 NCCL 컨테이너 이미지 준비

**NCCL Tests가 포함된 이미지를 Build:**

해당 예제에서는 [aws-samples/awsome-distributed-training](https://github.com/aws-samples/awsome-distributed-training/tree/main) 에서 제공하고 있는 [nccl-tests 예제](https://github.com/aws-samples/awsome-distributed-training/tree/main/micro-benchmarks/nccl-tests)를 활용 합니다.


```bash
git clone https://github.com/aws-samples/awsome-distributed-training.git

cd awsome-distributed-training/micro-benchmarks/nccl-tests/


GDRCOPY_VERSION=v2.5.1
EFA_INSTALLER_VERSION=1.43.2
AWS_OFI_NCCL_VERSION=v1.16.3
NCCL_VERSION=v2.27.7-1
NCCL_TESTS_VERSION=v2.16.9
TAG="efa${EFA_INSTALLER_VERSION}-ofi${AWS_OFI_NCCL_VERSION}-nccl${NCCL_VERSION}-tests${NCCL_TESTS_VERSION}"
CONTAINER_IMAGE_NAME_TAG="nccl-tests:${TAG}"

docker build -f nccl-tests.Dockerfile \
       --build-arg="EFA_INSTALLER_VERSION=${EFA_INSTALLER_VERSION}" \
       --build-arg="AWS_OFI_NCCL_VERSION=${AWS_OFI_NCCL_VERSION}" \
       --build-arg="NCCL_VERSION=${NCCL_VERSION}" \
       --build-arg="NCCL_TESTS_VERSION=${NCCL_TESTS_VERSION}" \
       -t ${CONTAINER_IMAGE_NAME_TAG} \
       .
```


생성 된 이미지를 확인 합니다.
```bash
docker images

IMAGE                                                        ID             DISK USAGE   CONTENT SIZE   EXTRA
nccl-tests:efa1.43.2-ofiv1.16.3-ncclv2.27.7-1-testsv2.16.9   db1587d2c248       18.3GB         6.52GB 
```

Build 된 이미지를 SQSH 로 변환 합니다.

```bash
enroot import -o /fsx/nccl-tests.sqsh dockerd://nccl-tests:efa1.43.2-ofiv1.16.3-ncclv2.27.7-1-testsv2.16.9
```

컨테이너에서 scontrol을 사용 할 수 있도록 세팅 합니다.
```bash
# Enroot Env 수정
srun -N 2 bash -c 'echo "ENROOT_ENVIRON PATH=/opt/slurm/bin:\$PATH" | sudo tee -a /etc/enroot/enroot.conf'

# 50-slurm-pmi.sh 수정
srun -N 2 sudo sed -i '2i export PATH=/opt/slurm/bin:$PATH' /etc/enroot/hooks.d/50-slurm-pmi.sh
```

---

### 4.1.2 테스트 스크립트 작성

```bash
cat << "EOF" > nccl-tests-container.sbatch
#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --job-name=nccl-all_reduce_perf # name of your job
#SBATCH --nodes=2 # number of nodes to use, 24 p4d(e) = 192 A100 GPUs
#SBATCH --ntasks-per-node 8 # Number of GPU per node
#SBATCH --gpus-per-node=8 # number of GPU we reserve. Uncomment for AWS ParallelCluster
#SBATCH --output %x_%j.out
#SBATCH --exclusive
#SBATCH --wait-all-nodes=1

### Disable hyperthreading by setting the tasks per core to 1
#SBATCH --ntasks-per-core=1

###########################
###### User Variables #####
###########################


# default variables for Enroot
: "${APPS_PATH:=/fsx}"
: "${NCCL_TESTS_PATH:=/opt/nccl-tests/build}"
: "${IMAGE:=$APPS_PATH/nccl-tests.sqsh}"

## Set libfabric flags to use EFA
export FI_PROVIDER=efa
export FI_EFA_FORK_SAFE=1

## Set this flag for debugging EFA
#export FI_LOG_LEVEL=warn

## NCCL Environment variables
export NCCL_DEBUG=INFO

### Increase the send queue depth and can turn NCCL communications into non-blocking.
### https://www.usenix.org/system/files/atc23-choi.pdf
export NCCL_BUFFSIZE=8388608
### Improve performance by increasing buffer size for Send/Recv, Gather, Scatter and Alltoall communications
### https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/usage/p2p.html
export NCCL_P2P_NET_CHUNKSIZE=524288

### Improve performance for AllReduce by selecting specific protocol and algorithm for specific
### message size and number of ranks.
### More information https://github.com/aws/aws-ofi-nccl/wiki/Algorithm-and-Protocol-Tuner-for-AWS.
export NCCL_TUNER_PLUGIN=/opt/amazon/ofi-nccl/lib/$(uname -m)-linux-gnu/libnccl-ofi-tuner.so

export NCCL_DEBUG=INFO
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export NCCL_SOCKET_IFNAME=enp
export GLOO_SOCKET_IFNAME=enp
export NCCL_IB_DISABLE=1


declare -a ARGS=(
    --container-image $IMAGE
    --container-mounts=/opt/slurm:/opt/slurm,/run/munge:/run/munge,/dev/infiniband:/dev/infiniband,/lustre:/lustre,/fsx:/fsx
)

#Get Hostname and Instance IDs
mpirun -N 1 bash -c 'echo $(hostname): $(cat /sys/devices/virtual/dmi/id/board_asset_tag | tr -d " ")'

# Run NCCL test
srun "${ARGS[@]}" --mpi=pmix --cpu-bind=none --container-env=PATH=/opt/slurm/bin:$PATH $NCCL_TESTS_PATH/all_reduce_perf -b 8 -e 16G -f 2 -g 1 -c 1 -n 100

EOF

```

---

## 4.2 다중 노드 테스트

### 4.2.1 노드 간 통신 테스트

**작업 제출 및 모니터링:**

```batch
# 작업 제출
sbatch nccl-tests-container.sbatch
```

```batch
# 작업 로그 확인
tail -f nccl-all_reduce_perf_1.out
```


✅ NCCL Tests 실행이 완료되었습니다!

> 💡 2025.12.02 일자 기준 ap-northeast-2(Sydney) 리전에서 2대의 p5e.48xlarge로 테스트 한 결과를 [99-appendix-nccl-test-results.md](./99-appendix-nccl-test-results.md)에서 확인 할 수 있습니다.


---

## 📚 네비게이션

| 이전 | 상위 | 다음 |
|------|------|------|
| [◀ 분산 학습](./03-distributed-training.md) | [📑 목차](../README.md#-가이드-목차) | Coming Soon |
