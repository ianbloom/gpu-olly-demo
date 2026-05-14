"""
Locust load generator for the GPU inference demo service.
Sends a realistic mix of short, medium, and long prompts.
"""
import random
from locust import HttpUser, task, between, events
from locust.runners import MasterRunner

SHORT_PROMPTS = [
    "What is machine learning?",
    "Explain transformers briefly.",
    "What are LLMs?",
    "Define gradient descent.",
    "What is CUDA?",
]

MEDIUM_PROMPTS = [
    "Explain how attention mechanisms work in transformer models and why they are effective for NLP tasks.",
    "Describe the differences between supervised, unsupervised, and reinforcement learning with examples.",
    "How does backpropagation work and what role does it play in training neural networks?",
    "What are the main architectural differences between GPT and BERT language models?",
    "Explain the concept of embeddings and how they capture semantic meaning.",
]

LONG_PROMPTS = [
    (
        "I am building a recommendation system for an e-commerce platform. "
        "Please explain in detail how collaborative filtering, content-based filtering, "
        "and hybrid approaches differ, including their trade-offs in terms of cold start "
        "problems, scalability, and data requirements. Also describe how modern deep "
        "learning approaches like neural collaborative filtering improve upon classic methods."
    ),
    (
        "Provide a comprehensive overview of large language model training, covering "
        "pre-training on large corpora, instruction fine-tuning, RLHF, and the role of "
        "compute in scaling laws. Include discussion of data quality, tokenization "
        "strategies, and the infrastructure needed to train at scale."
    ),
]


class InferenceUser(HttpUser):
    wait_time = between(0.5, 2.0)

    @task(5)
    def generate_short(self):
        self.client.post(
            "/generate",
            json={
                "prompt": random.choice(SHORT_PROMPTS),
                "max_tokens": random.randint(64, 128),
                "temperature": round(random.uniform(0.3, 1.0), 2),
            },
            name="/generate [short]",
        )

    @task(3)
    def generate_medium(self):
        self.client.post(
            "/generate",
            json={
                "prompt": random.choice(MEDIUM_PROMPTS),
                "max_tokens": random.randint(128, 256),
                "temperature": round(random.uniform(0.5, 0.9), 2),
            },
            name="/generate [medium]",
        )

    @task(2)
    def generate_long(self):
        self.client.post(
            "/generate",
            json={
                "prompt": random.choice(LONG_PROMPTS),
                "max_tokens": random.randint(256, 512),
                "temperature": round(random.uniform(0.6, 0.8), 2),
            },
            name="/generate [long]",
        )

    @task(1)
    def healthcheck(self):
        self.client.get("/healthz", name="/healthz")
