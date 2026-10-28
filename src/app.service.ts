import { Injectable } from '@nestjs/common';

@Injectable()
export class AppService {
  // A field belongs to this service instance and survives individual requests.
  private count = 0;

  increment(): { count: number } {
    this.count += 1;
    return { count: this.count };
  }
}
