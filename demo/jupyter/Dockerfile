FROM python:3.12-slim

WORKDIR /app

ENV PYTHONPATH=/app

# Install messaging lib dependencies + jupyter
COPY messaging /app/messaging
COPY demo/backend/requirements.txt /tmp/backend-requirements.txt
RUN pip install --no-cache-dir -r /tmp/backend-requirements.txt jupyterlab

# Pre-load notebooks
COPY demo/jupyter/notebooks /app/notebooks

EXPOSE 8888
CMD ["jupyter", "lab", \
     "--ip=0.0.0.0", "--port=8888", \
     "--no-browser", "--allow-root", \
     "--IdentityProvider.token=''", \
     "--ServerApp.base_url=/jupyter", \
     "--ServerApp.allow_origin=*", \
     "--notebook-dir=/app/notebooks"]
