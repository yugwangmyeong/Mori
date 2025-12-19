import { Server as SocketIOServer } from 'socket.io';
import { Server as HTTPServer } from 'http';
import prisma from './prisma';

export interface WebRTCMessage {
  type: 'offer' | 'answer' | 'ice-candidate' | 'session-request' | 'session-response';
  sessionId?: string;
  data?: any;
  targetId?: string;
}

export class WebRTCSignalingServer {
  private io: SocketIOServer;
  private activeSessions: Map<string, Set<string>> = new Map(); // sessionId -> Set of socketIds

  constructor(httpServer: HTTPServer) {
    this.io = new SocketIOServer(httpServer, {
      cors: {
        origin: process.env.CORS_ORIGIN || '*',
        methods: ['GET', 'POST'],
        credentials: true,
      },
    });

    this.setupEventHandlers();
  }

  private setupEventHandlers() {
    this.io.on('connection', (socket) => {
      console.log(`🔌 Client connected: ${socket.id}`);

      // Handle WebRTC signaling messages
      socket.on('webrtc-signal', async (message: WebRTCMessage) => {
        try {
          await this.handleSignal(socket, message);
        } catch (error) {
          console.error('Error handling WebRTC signal:', error);
          socket.emit('webrtc-error', { error: 'Failed to process signal' });
        }
      });

      // Handle session creation
      socket.on('create-session', async (data: { userId?: string }) => {
        try {
          const sessionId = this.generateSessionId();
          socket.join(sessionId);
          
          if (!this.activeSessions.has(sessionId)) {
            this.activeSessions.set(sessionId, new Set());
          }
          this.activeSessions.get(sessionId)!.add(socket.id);

          // Save session to database if userId provided
          if (data.userId) {
            await prisma.voiceSession.create({
              data: {
                userId: data.userId,
                sessionId,
                status: 'active',
              },
            });
          }

          socket.emit('session-created', { sessionId });
          console.log(`📹 Session created: ${sessionId} for socket ${socket.id}`);
        } catch (error) {
          console.error('Error creating session:', error);
          socket.emit('session-error', { error: 'Failed to create session' });
        }
      });

      // Handle session join
      socket.on('join-session', async (data: { sessionId: string; userId?: string }) => {
        try {
          const { sessionId, userId } = data;
          
          // Verify session exists
          const session = await prisma.voiceSession.findUnique({
            where: { sessionId },
          });

          if (!session || session.status !== 'active') {
            socket.emit('session-error', { error: 'Session not found or inactive' });
            return;
          }

          socket.join(sessionId);
          
          if (!this.activeSessions.has(sessionId)) {
            this.activeSessions.set(sessionId, new Set());
          }
          this.activeSessions.get(sessionId)!.add(socket.id);

          socket.emit('session-joined', { sessionId });
          
          // Notify other participants
          socket.to(sessionId).emit('peer-joined', { socketId: socket.id });
          
          console.log(`👥 Socket ${socket.id} joined session: ${sessionId}`);
        } catch (error) {
          console.error('Error joining session:', error);
          socket.emit('session-error', { error: 'Failed to join session' });
        }
      });

      // Handle session leave
      socket.on('leave-session', async (data: { sessionId: string }) => {
        try {
          const { sessionId } = data;
          socket.leave(sessionId);
          
          const session = this.activeSessions.get(sessionId);
          if (session) {
            session.delete(socket.id);
            if (session.size === 0) {
              this.activeSessions.delete(sessionId);
              
              // Update session status in database
              await prisma.voiceSession.updateMany({
                where: { sessionId },
                data: { status: 'ended', endedAt: new Date() },
              });
            }
          }

          socket.to(sessionId).emit('peer-left', { socketId: socket.id });
          console.log(`👋 Socket ${socket.id} left session: ${sessionId}`);
        } catch (error) {
          console.error('Error leaving session:', error);
        }
      });

      // Handle disconnection
      socket.on('disconnect', async () => {
        console.log(`🔌 Client disconnected: ${socket.id}`);
        
        // Clean up sessions
        for (const [sessionId, sockets] of this.activeSessions.entries()) {
          if (sockets.has(socket.id)) {
            sockets.delete(socket.id);
            socket.to(sessionId).emit('peer-left', { socketId: socket.id });
            
            if (sockets.size === 0) {
              this.activeSessions.delete(sessionId);
              
              // Update session status in database
              await prisma.voiceSession.updateMany({
                where: { sessionId },
                data: { status: 'ended', endedAt: new Date() },
              });
            }
          }
        }
      });
    });
  }

  private async handleSignal(socket: any, message: WebRTCMessage) {
    const { type, sessionId, data, targetId } = message;

    if (!sessionId) {
      socket.emit('webrtc-error', { error: 'Session ID required' });
      return;
    }

    // Verify socket is in the session
    const rooms = Array.from(socket.rooms);
    if (!rooms.includes(sessionId)) {
      socket.emit('webrtc-error', { error: 'Not a member of this session' });
      return;
    }

    // Forward signal to other participants in the session
    if (targetId) {
      // Send to specific target
      socket.to(targetId).emit('webrtc-signal', message);
    } else {
      // Broadcast to all other participants in the session
      socket.to(sessionId).emit('webrtc-signal', {
        ...message,
        senderId: socket.id,
      });
    }

    console.log(`📡 WebRTC signal forwarded: ${type} in session ${sessionId}`);
  }

  private generateSessionId(): string {
    return `session_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
  }

  public getIO(): SocketIOServer {
    return this.io;
  }
}

