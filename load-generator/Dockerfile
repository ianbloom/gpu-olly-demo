FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    opentelemetry-bootstrap -a install

COPY locustfile.py .

ENV PYTHONUNBUFFERED=1
EXPOSE 8089

# Headless mode by default; override HOST/USERS/SPAWN_RATE via env
CMD ["sh", "-c", \
     "opentelemetry-instrument locust --headless \
             --host=${TARGET_HOST:-http://gpu-inference.ai-demo.svc.cluster.local} \
             --users=${LOCUST_USERS:-20} \
             --spawn-rate=${LOCUST_SPAWN_RATE:-2} \
             --run-time=${LOCUST_RUN_TIME:-0} \
             -f locustfile.py"]
