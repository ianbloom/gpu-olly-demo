"""
Locust load generator for the GPU inference demo service.
Sends a realistic mix of short, medium, and long prompts.
Each simulated user maintains a persistent conversation_id so
multi-turn sessions appear grouped in Grafana AI Observability.
"""
import uuid
import random
from locust import HttpUser, task, between

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

    def on_start(self):
        # One stable conversation ID per simulated user — groups all turns
        # from this user into a single conversation in Grafana AI Observability.
        self.conversation_id = str(uuid.uuid4())

    def _post(self, prompt: str, max_tokens: int, name: str):
        self.client.post(
            "/generate",
            json={
                "prompt":          prompt,
                "max_tokens":      max_tokens,
                "temperature":     round(random.uniform(0.3, 1.0), 2),
                "conversation_id": self.conversation_id,
            },
            name=name,
        )

    @task(5)
    def generate_short(self):
        self._post(random.choice(SHORT_PROMPTS), random.randint(64, 128), "/generate [short]")

    @task(3)
    def generate_medium(self):
        self._post(random.choice(MEDIUM_PROMPTS), random.randint(128, 256), "/generate [medium]")

    @task(2)
    def generate_long(self):
        self._post(random.choice(LONG_PROMPTS), random.randint(256, 512), "/generate [long]")

    @task(1)
    def healthcheck(self):
        self.client.get("/healthz", name="/healthz")
