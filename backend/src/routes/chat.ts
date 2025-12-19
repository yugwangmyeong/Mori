import { Router, Request, Response } from 'express';
import { ChatRequest, ChatResponse, ErrorResponse } from '../types';
import prisma from '../lib/prisma';

const router = Router();

// POST /api/chat
router.post('/', async (req: Request<{}, ChatResponse | ErrorResponse, ChatRequest>, res: Response<ChatResponse | ErrorResponse>) => {
  try {
    const { message, userId } = req.body;
    
    if (!message) {
      return res.status(400).json({ error: 'Message is required' });
    }

    // TODO: Implement actual chatbot logic
    // For now, return a simple response
    const botResponse = '응답이 여기에 표시됩니다.';

    // Save chat message to database if userId is provided
    let chatMessage = null;
    if (userId) {
      try {
        chatMessage = await prisma.chatMessage.create({
          data: {
            userId,
            message,
            response: botResponse,
          },
        });
      } catch (dbError) {
        console.error('Error saving chat message to database:', dbError);
        // Continue even if database save fails
      }
    }

    const response: ChatResponse = {
      message: botResponse,
      timestamp: new Date().toISOString(),
      messageId: chatMessage?.id,
    };

    res.json(response);
  } catch (error) {
    console.error('Error processing chat message:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// GET /api/chat/history/:userId - Get chat history for a user
router.get('/history/:userId', async (req: Request, res: Response) => {
  try {
    const { userId } = req.params;
    const limit = parseInt(req.query.limit as string) || 50;
    const offset = parseInt(req.query.offset as string) || 0;

    const messages = await prisma.chatMessage.findMany({
      where: { userId },
      orderBy: { createdAt: 'desc' },
      take: limit,
      skip: offset,
    });

    res.json({ messages: messages.reverse() }); // Reverse to get chronological order
  } catch (error) {
    console.error('Error fetching chat history:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default router;

