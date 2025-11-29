import os
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, Trainer, TrainingArguments
from torch.utils.data import Dataset

os.makedirs("/root/.triton/autotune", exist_ok=True)

class DummyDataset(Dataset):
    def __init__(self, tokenizer, num_samples=200):
        self.tokenizer = tokenizer
        self.num_samples = num_samples
        self.texts = [
            "Hello, how are you today?",
            "Machine learning is amazing.",
            "Python is a powerful language.",
            "Deep learning transforms AI.",
        ] * (num_samples // 4)
    
    def __len__(self):
        return self.num_samples
    
    def __getitem__(self, idx):
        text = self.texts[idx]
        encodings = self.tokenizer(
            text,
            truncation=True,
            max_length=256,
            padding="max_length",
            return_tensors="pt"
        )
        return {
            'input_ids': encodings.input_ids.squeeze(),
            'attention_mask': encodings.attention_mask.squeeze(),
            'labels': encodings.input_ids.squeeze()
        }

def main():
    # 분산 환경 정보
    local_rank = int(os.environ.get('LOCAL_RANK', 0))
    world_size = int(os.environ.get('WORLD_SIZE', 1))
    rank = int(os.environ.get('RANK', 0))
    
    node_name = "Master (172.31.37.3)" if rank == 0 else "Worker (172.31.44.156)"
    print(f"🚀 [Rank {rank}/{world_size}] {node_name} GPU {local_rank} - Starting...")
    
    # 모델 로드
    print(f"[Rank {rank}] Loading Qwen 0.5B...")
    model = AutoModelForCausalLM.from_pretrained(
        "Qwen/Qwen2.5-0.5B",
        attn_implementation="flash_attention_2",
        torch_dtype=torch.bfloat16,
    )
    
    tokenizer = AutoTokenizer.from_pretrained("Qwen/Qwen2.5-0.5B")
    tokenizer.pad_token = tokenizer.eos_token
    
    print(f"[Rank {rank}] Preparing dataset...")
    dataset = DummyDataset(tokenizer, num_samples=200)
    
    print(f"[Rank {rank}] Setting up DeepSpeed training...")
    training_args = TrainingArguments(
        output_dir="./results",
        num_train_epochs=2,
        per_device_train_batch_size=4,
        gradient_accumulation_steps=2,
        logging_steps=5,
        bf16=True,
        learning_rate=2e-5,
        warmup_steps=10,
        report_to="none",
        logging_first_step=True,
        deepspeed="ds_config.json",
        ddp_backend="nccl",
    )
    
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
    )
    
    print(f"🏋️  [Rank {rank}] Starting distributed training with DeepSpeed...")
    trainer.train()
    
    if rank == 0:
        print("\n" + "="*60)
        print("✅ Multi-node DeepSpeed training completed!")
        print("🎉 2 nodes, 2 GPUs successfully trained together!")
        print("="*60)

if __name__ == "__main__":
    main()