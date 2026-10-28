import { AppService } from './app.service.js';

describe('Count service state', () => {
  it('increments across calls and starts fresh for a new instance', () => {
    const service = new AppService();
    expect(service.increment()).toEqual({ count: 1 });
    expect(service.increment()).toEqual({ count: 2 });
    expect(new AppService().increment()).toEqual({ count: 1 });
  });
});
