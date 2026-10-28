# Count API

This is Dom's assignment: each `GET /count` call increments one counter and returns its updated value as JSON. Start here before the other examples.

## Run and observe

```bash
cd ~/Documents/CodingProjects/count
npm run start:dev
```

In a second terminal, send these requests one at a time:

```bash
curl -i http://localhost:3000/count
curl -i http://localhost:3000/count
curl -i http://localhost:3000/count
```

On a fresh server, the responses have status 200 and bodies `{"count":1}`, `{"count":2}`, and `{"count":3}`. Other requests already made to `/count` will have advanced the number. Visiting `/` now returns 404 because this project registers `/count` only.

Postman: choose GET, enter `http://localhost:3000/count`, and press Send repeatedly. Compare the returned number. A browser can also send GET requests by opening that URL.

## Follow one request through the code

Read `src/app.controller.ts`, then `src/app.service.ts`, `src/app.module.ts`, and `src/main.ts`.

1. `@Controller('count')` supplies the path prefix. `@Get()` adds no path, so together they match GET /count.
2. Nest calls the controller's `increment()` method. Its name does not determine the URL.
3. `this.appService.increment()` calls the service instance Nest supplied through the constructor.
4. `private count = 0` initializes a field when the service is created. It is outside the method, so it is not reinitialized for each call.
5. `this.count += 1` changes that field. The returned object becomes JSON in the HTTP response.

`@Injectable()` marks the service as available for Nest's dependency injection. The module's `providers` list registers it. In the constructor, TypeScript's `private readonly appService: AppService` syntax creates a field and stores the injected service there. `readonly` prevents reassigning that reference; it does not freeze the service's counter.

The return annotation `{ count: number }` describes an object containing a numeric count. It is a TypeScript type, not the response value itself. `@Header('Cache-Control', 'no-store')` asks clients and intermediaries not to cache responses.

## State and HTTP semantics

Every request to this route changes state, regardless of whether it comes from a browser, Postman, or curl. Restarting this process resets its counter; the first subsequent request returns 1. A source edit in watch mode also restarts it.

This GET behavior deliberately follows the assignment. Normal API design treats GET as safe and uses a method such as POST for an increment operation. Retries or automatic requests can increment this example unexpectedly. Later, compare this with the explicit mutation routes in Tasks.

## Check your understanding

Before editing anything, explain why placing `let count = 0` inside `increment()` would change the result of repeated calls.

Then try these exercises, one at a time. Predict the response before sending the request. No solutions are included.

1. Change the route to `/visits` while keeping the behavior. Which file needs to change? Test both the old and new URLs.
2. Add a separate GET route that returns the current value without incrementing it. Decide what it should return before the first increment.
3. Add a POST route that resets the counter. Test increment → increment → reset → increment. Do not let an ordinary read reset the count.

## Verification

```bash
npm run build
npm test
npm run test:e2e
```

The HTTP tests check successive increments, initial state in a fresh application, and the unregistered root route. Tests will need updating if you deliberately change the route during an exercise.
