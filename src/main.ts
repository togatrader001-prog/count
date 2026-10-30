import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module.js';
import { readTlsOptions } from './tls-options.js';

async function bootstrap() {
  const httpsOptions = readTlsOptions(process.env.COUNT_TLS_BUNDLE);
  if (process.env.PORT === '443' && !httpsOptions) {
    throw new Error('TLS bundle required for HTTPS port');
  }
  const app = await NestFactory.create(AppModule, { httpsOptions });
  await app.listen(process.env.PORT ?? (httpsOptions ? 443 : 3000));
}
await bootstrap();
