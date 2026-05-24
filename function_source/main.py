"""PDF -> Document AI -> JSON. Triggered by GCS object.finalize via Eventarc."""

import json
import logging
import os
from datetime import datetime, timezone

import functions_framework

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("pdf-pipeline")

# Lazily-initialised singletons so a bad env var or a slow import does not
# kill the container during the Cloud Run health check.
_storage_client = None
_docai_client = None


def _storage():
    global _storage_client
    if _storage_client is None:
        from google.cloud import storage
        _storage_client = storage.Client()
    return _storage_client


def _docai():
    global _docai_client
    if _docai_client is None:
        from google.api_core.client_options import ClientOptions
        from google.cloud import documentai_v1 as documentai
        location = os.environ["DOCAI_LOCATION"]
        _docai_client = documentai.DocumentProcessorServiceClient(
            client_options=ClientOptions(
                api_endpoint=f"{location}-documentai.googleapis.com"
            )
        )
    return _docai_client


@functions_framework.cloud_event
def process_pdf(cloud_event):
    from google.cloud import documentai_v1 as documentai

    data = cloud_event.data or {}
    bucket = data.get("bucket")
    name = data.get("name")
    ctype = data.get("contentType", "")

    if not bucket or not name:
        log.warning("Event missing bucket/name: %s", data)
        return

    if not name.lower().endswith(".pdf") and "pdf" not in ctype.lower():
        log.info("Skipping non-PDF: gs://%s/%s (%s)", bucket, name, ctype)
        return

    log.info("Processing gs://%s/%s", bucket, name)
    pdf_bytes = _storage().bucket(bucket).blob(name).download_as_bytes()

    processor = os.environ["DOCAI_PROCESSOR_ID"]
    result = _docai().process_document(
        request=documentai.ProcessRequest(
            name=processor,
            raw_document=documentai.RawDocument(
                content=pdf_bytes, mime_type="application/pdf"
            ),
        )
    )
    doc = result.document

    payload = {
        "source": {
            "bucket": bucket,
            "object": name,
            "processed_at": datetime.now(timezone.utc).isoformat(),
        },
        "text": doc.text,
        "pages": [
            {
                "page_number": p.page_number,
                "blocks": len(p.blocks),
                "paragraphs": len(p.paragraphs),
                "lines": len(p.lines),
                "tokens": len(p.tokens),
                "languages": [l.language_code for l in p.detected_languages],
            }
            for p in doc.pages
        ],
    }

    out_name = name.rsplit(".", 1)[0] + ".json"
    _storage().bucket(os.environ["OUTPUT_BUCKET"]).blob(out_name).upload_from_string(
        json.dumps(payload, ensure_ascii=False, indent=2),
        content_type="application/json",
    )
    log.info("Wrote gs://%s/%s (%d pages)",
             os.environ["OUTPUT_BUCKET"], out_name, len(doc.pages))
