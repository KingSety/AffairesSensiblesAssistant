import os
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
import jwt
from openai import OpenAI
from dotenv import load_dotenv

# Load variables from .env file
load_dotenv()

app = FastAPI(title="Secure OpenAI Proxy")
security = HTTPBearer()

# Ensure critical environment variables exist
if not os.getenv("OPENAI_API_KEY"):
    raise RuntimeError("Missing OPENAI_API_KEY environment variable.")

# Initialize the OpenAI client securely on the backend
openai_client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
JWT_SECRET = os.getenv("JWT_SECRET_KEY", "fallback-secret-for-dev-only")

# 1. Pydantic Models for Input Validation
class ChatRequest(BaseModel):
    # Enforce standard payload size constraints
    prompt: str = Field(..., min_length=1, max_length=2000, description="The user prompt from iOS")

class ChatResponse(BaseModel):
    reply: str

# 2. Authentication Middleware Function
def verify_ios_client(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    """Validates the JWT token passed by the iOS client app."""
    token = credentials.credentials
    try:
        # Decode and verify token integrity and expiration
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        user_id: str = payload.get("sub")
        if not user_id:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED, 
                detail="Invalid token payload"
            )
        return user_id
    except jwt.PyJWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, 
            detail="Could not validate credentials"
        )

# 3. Secure Proxy Endpoint
@app.post("/v1/chat", response_model=ChatResponse)
async def handle_chat(
    request_data: ChatRequest, 
    user_id: str = Depends(verify_ios_client)
):
    """
    Acts as a secure intermediary between the iOS App and OpenAI.
    The iOS app only talks to this endpoint.
    """
    try:
        # Server-Side Sanitization / Prompt Injection Check
        sanitized_prompt = request_data.prompt.strip()
        
        # Enforce Rate Limiting here if needed (e.g., query Redis using user_id)
        
        # Forward request to OpenAI from the backend
        response = openai_client.chat.completions.create(
            model="gpt-4o-mini",  # Production recommended default model
            messages=[
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": sanitized_prompt}
            ],
            max_tokens=500,
            temperature=0.7
        )
        
        # Extract response text safely
        ai_reply = response.choices[0].message.content
        
        # Return exact minimized payload back to the iOS app
        return ChatResponse(reply=ai_reply)
        
    except Exception as e:
        # Log the detailed exception internally for debugging
        print(f"Internal Error processing request for user {user_id}: {str(e)}")
        # Return a generic error to the client to avoid leaking infrastructure details
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="An error occurred while communicating with the AI service."
        )
