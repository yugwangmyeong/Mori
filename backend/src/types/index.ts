export interface ChatRequest {
  message: string;
  userId?: string;
}

export interface ChatResponse {
  message: string;
  timestamp: string;
  messageId?: string;
}

export interface VoiceRequest {
  audio?: string; // Base64 encoded audio or file path
}

export interface VoiceResponse {
  message: string;
  timestamp: string;
}

export interface ErrorResponse {
  error: string;
}

