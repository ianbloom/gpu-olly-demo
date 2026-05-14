FROM pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    opentelemetry-bootstrap -a install

COPY app.py .

ENV PYTHONUNBUFFERED=1
EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
