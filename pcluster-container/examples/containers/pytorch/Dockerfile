FROM public.ecr.aws/deep-learning-containers/pytorch-training:2.5.1-gpu-py311-cu124-ubuntu22.04-ec2-v1.30

RUN apt-get update && apt-get install -y \
    openssh-server \
    pdsh \
    net-tools \
    && rm -rf /var/lib/apt/lists/*

RUN pip install \
    transformers>=4.37.0 \
    flash-attn --no-build-isolation \
    deepspeed \
    accelerate \
    datasets

WORKDIR /workspace

COPY ds_config.json /workspace/
COPY train_distributed_deepspeed.py /workspace/