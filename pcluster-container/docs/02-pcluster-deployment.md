## 2. ParallelCluster 배포

> 💡 **목표:** AWS ParallelCluster를 생성하고 Slurm 스케줄러를 설정합니다.

⏱️ **예상 소요 시간:** 30-40분

## 목차

- [개요](#개요)
- [2.1 클러스터 설정 파일 준비](#21-클러스터-설정-파일-준비)
- [2.2 클러스터 생성](#22-클러스터-생성)
- [2.3 클러스터 접속 및 검증](#23-클러스터-접속-및-검증)
- [2.4 Slurm 기본 사용](#24-slurm-기본-사용)
- [다음 단계](#다음-단계)

---

## 개요

이 문서에서는 다음 작업을 수행합니다:

- ✅ ParallelCluster 설정 파일 작성
- ✅ 클러스터 생성 및 검증
- ✅ Slurm 기본 명령어 사용 (nvidia-smi w/ srun)

---

## 2.1 클러스터 설정 파일 준비

ParallelCluster 생성을 위한 YAML 설정 파일을 준비합니다.

### 환경 변수 확인

먼저 이전 단계에서 설정한 환경 변수들이 로드되어 있는지 확인합니다:

```bash
# 환경 변수 로드
source ~/pcluster-env.sh

# 주요 변수 확인
echo "Region: ${AWS_REGION}"
echo "VPC ID: ${VPC_ID}"
echo "Public Subnet: ${PUBLIC_SUBNET_ID}"
echo "Private Subnet: ${PRIVATE_SUBNET_ID}"
echo "Security Group: ${SECURITY_GROUP_ID}"
echo "FSx Lustre ID: ${FSX_LUSTRE_ID}"
echo "FSx OpenZFS Volume ID: ${FSX_OPENZFS_ROOT_VOLUME_ID}"
echo "Head Node Bootstrap: ${HEAD_NODE_BOOTSTRAP_SCRIPT}"
echo "Compute Node Bootstrap: ${COMPUTE_NODE_BOOTSTRAP_SCRIPT}"
```

### 클러스터 설정 파일 생성

환경 변수를 사용하여 클러스터 설정 파일을 생성합니다:

> 📝 **템플릿 파일 참조:**
> - 전체 설정 파일 템플릿은 [examples/templates/cluster-config.yaml.template](../examples/templates/cluster-config.yaml.template)에서 확인할 수 있습니다.
> - 아래 명령은 환경 변수를 사용하여 템플릿을 실제 설정 파일로 변환합니다.

```bash
# 설정 파일 디렉토리로 이동
cd ~/distributed-training-on-aws/pcluster-container

# 인스턴스 타입 및 수량 설정 (필요시 변경)
export COMPUTE_INSTANCE_TYPE=g5.8xlarge
export COMPUTE_MIN_COUNT=2
export COMPUTE_MAX_COUNT=2

# 클러스터 설정 파일 생성
cat > examples/configs/cluster-config.yaml << EOF
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
Region: ${AWS_REGION}

DevSettings:
  Timeouts:
    HeadNodeBootstrapTimeout: 43200  # 12 hours
    ComputeNodeBootstrapTimeout: 7200  # 2 hours

Imds:
  ImdsSupport: v2.0

Image:
  Os: ubuntu2204

HeadNode:
  InstanceType: m5.8xlarge
  Networking:
    SubnetId: ${PUBLIC_SUBNET_ID}
    ElasticIp: false
    AdditionalSecurityGroups:
      - ${SECURITY_GROUP_ID}
  LocalStorage:
    RootVolume:
      Size: 500
      DeleteOnTermination: true  # Root and /home volume for users
  Iam:
    AdditionalIamPolicies:
      # Grant ECR, SSM and S3 access
      - Policy: arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
      - Policy: arn:aws:iam::aws:policy/AmazonS3FullAccess
      - Policy: arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
      - Policy: arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicFullAccess
  CustomActions:
    OnNodeConfigured:
      Sequence:
        - Script: 'https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-post-install-scripts/main/docker/postinstall.sh'
        - Script: '${HEAD_NODE_BOOTSTRAP_SCRIPT}'

Scheduling:
  Scheduler: slurm
  SlurmSettings:
    ScaledownIdletime: -1  # Disable automatic scale-down
    QueueUpdateStrategy: DRAIN
    CustomSlurmSettings:
      # Simple accounting to text file
      - JobCompType: jobcomp/filetxt
      - JobCompLoc: /home/slurm/slurm-job-completions.txt
      - JobAcctGatherType: jobacct_gather/linux
      # Increase timeout before marking node as DOWN
      - SlurmdTimeout: 1000
  SlurmQueues:
    - Name: compute-gpu
      CapacityType: ONDEMAND
      Networking:
        SubnetIds:
          - ${PRIVATE_SUBNET_ID}
        PlacementGroup:
          Enabled: true
        AdditionalSecurityGroups:
          - ${SECURITY_GROUP_ID}
      ComputeSettings:
        LocalStorage:
          EphemeralVolume:
            MountDir: /scratch  # Local NVMe scratch space
          RootVolume:
            Size: 512
      JobExclusiveAllocation: true  # Each job gets exclusive access to nodes
      ComputeResources:
        - Name: distributed-ml
          InstanceType: ${COMPUTE_INSTANCE_TYPE}
          MinCount: ${COMPUTE_MIN_COUNT}
          MaxCount: ${COMPUTE_MAX_COUNT}
          # Capacity Reservation configuration (uncomment if using Capacity Block/Reservation)
          # CapacityReservationTarget:
          #   CapacityReservationId: cr-0a1f6b92ded769450  # Replace with your Capacity Reservation ID
          Efa:
            Enabled: true
            #GdrSupport: true  # GPUDirect RDMA for p4d/p5 instances
      Iam:
        AdditionalIamPolicies:
          - Policy: arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
          - Policy: arn:aws:iam::aws:policy/AmazonS3FullAccess
          - Policy: arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
          - Policy: arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicFullAccess
      CustomActions:
        OnNodeConfigured:
          Sequence:
            - Script: 'https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-post-install-scripts/main/docker/postinstall.sh'
            - Script: '${COMPUTE_NODE_BOOTSTRAP_SCRIPT}'

SharedStorage:
  - Name: shared-workspace-zfs
    StorageType: FsxOpenZfs
    MountDir: /fsx
    FsxOpenZfsSettings:
      VolumeId: ${FSX_OPENZFS_ROOT_VOLUME_ID}

  - Name: fsx-lustre
    MountDir: /lustre
    StorageType: FsxLustre
    FsxLustreSettings:
      FileSystemId: ${FSX_LUSTRE_ID}
      DeploymentType: PERSISTENT_1

Monitoring:
  DetailedMonitoring: true
  Logs:
    CloudWatch:
      Enabled: true
  Dashboards:
    CloudWatch:
      Enabled: true
EOF

echo "✅ Cluster configuration file created: examples/configs/cluster-config.yaml"
```

### 설정 파일 주요 구성 요소

**HeadNode 설정:**
- **InstanceType**: `m5.8xlarge` - 32 vCPU, 128GB RAM (Slurm 컨트롤러용)
- **SubnetId**: Public 서브넷 사용 (Session Manager 접속용)
- **RootVolume**: 500GB (사용자 홈 디렉토리 포함)
- **CustomActions**: Docker 및 Enroot/Pyxis 설치 스크립트

**Compute Node 설정:**
- **InstanceType**: `p5.8xlarge` - A10G GPU
- **SubnetId**: Private 서브넷 사용
- **MinCount/MaxCount**: 2 노드 (필요에 따라 조정 가능)
- **EFA**: Enabled
- **LocalStorage**: 
  - `/scratch`: NVMe 기반 임시 스토리지
  - Root Volume: 512GB

**Slurm 설정:**
- **ScaledownIdletime**: -1 (자동 스케일다운 비활성화)
- **JobExclusiveAllocation**: true (노드 독점 할당)
- **QueueUpdateStrategy**: DRAIN

**SharedStorage:**
- **FSx OpenZFS** (`/fsx`): Home 디렉토리 및 사용자 데이터
- **FSx Lustre** (`/lustre`): 학습 데이터셋

### 설정 파일 검증

생성된 설정 파일을 확인합니다:

```bash
# 설정 파일 내용 확인
cat examples/configs/cluster-config.yaml

# ParallelCluster CLI로 검증
pcluster validate-config \
  --config-file examples/configs/cluster-config.yaml \
  --region ${AWS_REGION}
```

**예상 출력:**
```json
{
  "message": "Configuration file is valid"
}
```

> ⚠️ **주의:**
> - 환경 변수가 제대로 치환되었는지 꼭 확인하세요.

---

## 2.2 클러스터 생성

### 클러스터 이름 설정

```bash
export CLUSTER_NAME=ml-training-cluster
```

### 클러스터 생성 시작

```bash
# 클러스터 생성
pcluster create-cluster \
  --cluster-name ${CLUSTER_NAME} \
  --cluster-configuration examples/configs/cluster-config.yaml \
  --region ${AWS_REGION}
```

**예상 출력:**
```json
{
  "cluster": {
    "clusterName": "ml-training-cluster",
    "cloudformationStackStatus": "CREATE_IN_PROGRESS",
    "cloudformationStackArn": "arn:aws:cloudformation:us-east-1:123456789012:stack/...",
    "region": "us-east-1",
    "version": "3.14.0",
    "clusterStatus": "CREATE_IN_PROGRESS"
  }
}
```

### 클러스터 생성 상태 모니터링

```bash
# 클러스터 상태 확인
pcluster describe-cluster \
  --cluster-name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query 'clusterStatus' \
  --output text
```

**예상 상태:**
- `CREATE_IN_PROGRESS`: 생성 중
- `CREATE_COMPLETE`: 생성 완료 ✅
- `CREATE_FAILED`: 생성 실패 ❌

> ⏱️ **예상 소요 시간: 약 25-35분**

### CloudFormation 스택 확인

```bash
# CloudFormation 스택 이벤트 확인
aws cloudformation describe-stack-events \
  --stack-name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --max-items 10 \
  --query 'StackEvents[*].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId]' \
  --output table
```

---

## 2.3 클러스터 접속 및 검증

클러스터 생성이 완료되면 Head Node에 접속하여 환경을 확인합니다.

### Head Node 접속

Session Manager를 통해 Head Node에 접속합니다:

```bash
# SSH 접속
pcluster ssh \
  --cluster-name ${CLUSTER_NAME} \
  --region ${AWS_REGION}
```

**예상 출력:**
```
Starting session with SessionId: user-0a1b2c3d4e5f6g7h8
ubuntu@ip-10-0-0-123:~$
```

> 💡 **Session Manager 사용:**
> - SSH 키 없이 안전하게 접속
> - IAM 기반 인증
> - 세션 로그 자동 기록

### 기본 환경 확인

Head Node에 접속한 후 다음 명령으로 환경을 확인합니다:

```bash
# OS 정보 확인
cat /etc/os-release

# 마운트된 공유 스토리지 확인
df -h | grep -E 'fsx|lustre'

# Docker 설치 확인
docker --version

# Enroot 설치 확인
enroot version

# Pyxis 설치 확인 (Slurm 플러그인)
ls -la /usr/local/lib/slurm/
```

**예상 출력:**
```
NAME="Ubuntu"
VERSION="22.04.x LTS (Jammy Jellyfish)"

Filesystem                          Size  Used Avail Use% Mounted on
10.0.1.xxx@tcp:/fsvol-xxx          512G   64M  512G   1% /fsx
10.0.1.yyy@tcp:/yyyyyyy            1.1T  1.1M  1.1T   1% /lustre

Docker version 24.0.x
enroot version 3.4.1

spank_pyxis.so
```

---

## 2.4 Slurm 기본 사용

### Slurm 노드 상태 확인

```bash
# 노드 정보 확인
sinfo
```

**예상 출력:**
```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
compute-gpu*  up   infinite      2  idle~ compute-gpu-distributed-ml-[1-4]
```

> 📝 **노드 상태:**
> - `idle~`: 유휴 상태, 필요 시 자동 프로비저닝
> - `alloc`: 작업에 할당됨
> - `mix`: 일부 리소스 사용 중
> - `down`: 사용 불가

### Slurm 파티션 확인

```bash
# 파티션 정보
scontrol show partition compute-gpu
```

### 간단한 nvidia-smi 테스트

Compute Node를 프로비저닝하고 GPU를 확인하는 간단한 테스트를 실행합니다:

```bash
# nvidia-smi 테스트 작업 제출
srun --partition=compute-gpu \
     --nodes=1 \
     --ntasks=1 \
     --gpus-per-node=1 \
     nvidia-smi
```

**예상 출력:**
```
TBU
```

### 작업 큐 확인

```bash
# 실행 중인 작업 확인
squeue

# 본인의 작업만 확인
squeue -u $USER

# 작업 상세 정보
scontrol show job <JOB_ID>
```

### Compute Node 상태 확인

```bash
# 프로비저닝된 노드 확인
sinfo

# 특정 노드 상세 정보
scontrol show node compute-gpu-distributed-ml-1
```

---

## 다음 단계

✅ ParallelCluster 배포가 완료되었습니다!

이제 **[3. 분산 학습 실행](./03-distributed-training.md)**으로 진행하여 실제 학습 작업을 실행하세요.

---

### 환경 변수 저장

```bash
# 클러스터 이름 저장
cat >> ~/pcluster-env.sh << EOF
export CLUSTER_NAME=${CLUSTER_NAME}
EOF
```

---

## 📚 네비게이션

| 이전 | 상위 | 다음 |
|------|------|------|
| [◀ 사전 요구사항](./01-prerequisites.md) | [📑 목차](../README.md#-가이드-목차) | [분산 학습 ▶](./03-distributed-training.md) |