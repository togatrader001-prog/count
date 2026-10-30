import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { AppModule } from '../src/app.module.js';

let app: INestApplication;
beforeEach(async () => {
  const module = await Test.createTestingModule({
    imports: [AppModule],
  }).compile();
  app = module.createNestApplication();
  await app.init();
});
afterEach(async () => {
  await app.close();
});

it('increments on every GET /count request', async () => {
  await request(app.getHttpServer())
    .get('/count')
    .expect(200)
    .expect({ count: 1 });
  await request(app.getHttpServer())
    .get('/count')
    .expect(200)
    .expect({ count: 2 });
});
it('starts a fresh app at zero and rejects an unregistered route', async () => {
  await request(app.getHttpServer())
    .get('/count')
    .expect(200)
    .expect({ count: 1 });
  await request(app.getHttpServer()).get('/').expect(404);
});
it('reports health without incrementing the counter', async () => {
  await request(app.getHttpServer()).get('/health').expect(200).expect({ status: 'ok' });
  await request(app.getHttpServer()).get('/count').expect(200).expect({ count: 1 });
});
