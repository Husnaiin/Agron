import os
from dotenv import load_dotenv
from huggingface_hub import InferenceClient

# Load environment variables from .env file
load_dotenv()

# Load API key from environment variable
client = InferenceClient(
    provider="hf-inference",
    api_key=os.environ["HF_TOKEN"],
)

def transcribe_audio(audio_file_path):
    """
    Transcribe audio file using Hugging Face's Whisper model
    
    Args:
        audio_file_path (str): Path to the audio file to transcribe
        
    Returns:
        str: Transcribed text
    """
    try:
        output = client.automatic_speech_recognition(audio_file_path, model="openai/whisper-large-v3")
        return output
    except Exception as e:
        print(f"Error transcribing audio: {e}")
        return None

if __name__ == "__main__":
    # Example usage
    audio_file = "audio1.ogg"
    
    if os.path.exists(audio_file):
        print(f"Transcribing {audio_file}...")
        result = transcribe_audio(audio_file)
        if result:
            print(f"Transcription: {result}")
        else:
            print("Transcription failed")
    else:
        print(f"Audio file {audio_file} not found")
