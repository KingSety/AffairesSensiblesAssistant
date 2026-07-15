Script for transcribing audio/video files with Deepgram, summarizing the
transcript with OpenAI, embedding the summary, and storing the vector in
Amazon S3 Vectors.

## Install dependencies

Run:

```bash
python3 -m pip install -r requirements.txt
```

## Configuration

Copy `.env.example` to `.env`, fill in the values, or export these environment
variables:

```bash
DEEPGRAM_API_KEY=...
OPENAI_API_KEY=...
AWS_REGION=us-east-1
S3_VECTOR_BUCKET_NAME=your-vector-bucket
S3_VECTOR_INDEX_NAME=your-vector-index
```

AWS credentials use boto3's normal credential chain, such as environment
variables, `~/.aws/credentials`, an IAM role, or AWS IAM Identity Center.

`OPENAI_SUMMARY_MODEL` is optional and defaults to `gpt-4.1-mini`. Summary
embeddings always use `text-embedding-3-small` with 1,536 dimensions.

The S3 vector bucket and index must already exist. Create the index with a
1,536-dimension `float32` vector type and the cosine distance metric, for
example:

```bash
aws s3vectors create-vector-bucket \
  --vector-bucket-name "$S3_VECTOR_BUCKET_NAME"

aws s3vectors create-index \
  --vector-bucket-name "$S3_VECTOR_BUCKET_NAME" \
  --index-name "$S3_VECTOR_INDEX_NAME" \
  --data-type float32 \
  --dimension 1536 \
  --distance-metric cosine \
  --metadata-configuration '{"nonFilterableMetadataKeys":["summary"]}'
```

The AWS identity running the script needs `s3vectors:PutVectors` permission
for the target index.

## Run the pipeline

Place supported audio/video files in `Audio/`, then run:

```bash
python3 deepgram_api.py
```

Transcripts are written to `Transcripts/`, summaries to `Summaries/`, and one
summary vector per audio file is upserted into the configured S3 vector index.
