FROM python:3.12-slim
WORKDIR /app
COPY --chown=10001:10001 --chmod=0444 app.py /app/app.py
RUN useradd --system --uid 10001 notifier
USER 10001
EXPOSE 8080
CMD ["python", "-u", "/app/app.py"]
