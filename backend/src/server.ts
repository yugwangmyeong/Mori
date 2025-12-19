import express, { Request, Response } from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import { createServer } from 'http';

// Import routes
import chatRoutes from './routes/chat';
import voiceRoutes from './routes/voice';
import authRoutes from './routes/auth';
import realtimeRoutes from './routes/realtime';

// Import WebRTC signaling server
import { WebRTCSignalingServer } from './lib/webrtc';

// Import Prisma client
import prisma from './lib/prisma';

dotenv.config();

const app = express();
const httpServer = createServer(app);
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors({
  origin: process.env.CORS_ORIGIN || '*',
  credentials: true,
}));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// 요청 로깅 미들웨어
app.use((req: Request, res: Response, next) => {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(`📨 ${req.method} ${req.path}`);
  console.log(`   From: ${req.ip || req.socket.remoteAddress}`);
  console.log(`   Time: ${new Date().toISOString()}`);
  if (req.body && Object.keys(req.body).length > 0) {
    console.log(`   Body: ${JSON.stringify(req.body).substring(0, 200)}...`);
  }
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  next();
});

// Routes
app.get('/health', async (req: Request, res: Response) => {
  try {
    console.log('🏥 Health check request received');
    
    // Test database connection
    await prisma.$queryRaw`SELECT 1`;
    
    const healthStatus = { 
      status: 'ok', 
      message: 'Mori backend server is running',
      database: 'connected',
      timestamp: new Date().toISOString()
    };
    
    console.log('✅ Health check passed:', healthStatus);
    res.json(healthStatus);
  } catch (error) {
    const healthStatus = { 
      status: 'ok', 
      message: 'Mori backend server is running',
      database: 'disconnected',
      error: error instanceof Error ? error.message : 'Unknown error',
      timestamp: new Date().toISOString()
    };
    
    console.log('⚠️ Health check - database disconnected:', healthStatus);
    res.json(healthStatus);
  }
});

// API routes
app.use('/api/auth', authRoutes);
app.use('/api/chat', chatRoutes);
app.use('/api/voice', voiceRoutes);
app.use('/api/realtime', realtimeRoutes);

// Initialize WebRTC signaling server
const webrtcServer = new WebRTCSignalingServer(httpServer);

// Graceful shutdown
process.on('SIGINT', async () => {
  console.log('\n🛑 Shutting down server...');
  await prisma.$disconnect();
  httpServer.close(() => {
    console.log('✅ Server closed');
    process.exit(0);
  });
});

// Start server
httpServer.listen(Number(PORT), '0.0.0.0', () => {
  console.log('═══════════════════════════════════════════════════════');
  console.log(`🚀 Mori backend server is running!`);
  console.log(`   Port: ${PORT}`);
  console.log(`   Local: http://localhost:${PORT}`);
  console.log(`   Network: http://0.0.0.0:${PORT}`);
  console.log(`📍 Health check: http://localhost:${PORT}/health`);
  console.log(`📍 API Base: http://localhost:${PORT}/api`);
  console.log(`📡 WebRTC signaling server ready`);
  console.log(`🎙️  OpenAI Realtime API ready (WebRTC: /api/realtime/webrtc/offer)`);
  console.log(`🌐 CORS Origin: ${process.env.CORS_ORIGIN || '*'}`);
  console.log('═══════════════════════════════════════════════════════');
  console.log('📝 Waiting for requests...');
  console.log('💡 To test from another device, use your computer\'s IP address');
  console.log('═══════════════════════════════════════════════════════');
});

