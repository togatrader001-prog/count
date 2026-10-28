import { Controller, Get, Header } from '@nestjs/common';
import { AppService } from './app.service.js';

@Controller('count')
export class AppController {
  // Nest supplies the service; this is dependency injection.
  constructor(private readonly appService: AppService) {}

  @Get()
  @Header('Cache-Control', 'no-store')
  increment(): { count: number } {
    return this.appService.increment();
  }
}
