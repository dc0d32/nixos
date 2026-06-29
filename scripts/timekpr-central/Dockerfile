FROM python:3.12-slim
RUN pip install --no-cache-dir fastapi==0.115.* "uvicorn[standard]==0.32.*" python-multipart==0.0.* \
    && useradd -u 10000 -m app && mkdir -p /data && chown app /data
USER app
WORKDIR /app
COPY app.py .
EXPOSE 8000
VOLUME /data
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request;urllib.request.urlopen('http://localhost:8000/health')"
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
