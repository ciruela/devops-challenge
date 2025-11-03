from flask import Flask, jsonify, request
import logging, sys, os

app = Flask("Ciruelaa")
logging.basicConfig(stream=sys.stdout, level=logging.INFO)

VERSION = os.getenv("APP_VERSION", os.getenv("VERSION", "v1"))
COLOR = os.getenv("APP_COLOR", "blue")


@app.route("/")
def index():
    app.logger.info("Request from %s to version %s color %s", request.remote_addr, VERSION, COLOR)
    return jsonify({
        "service": "content-api",
        "version": VERSION,
        "color": COLOR,
        "message": f"Hello from {COLOR} version {VERSION}"
    })


@app.route("/healthz")
def health():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
