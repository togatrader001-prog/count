import { defineConfig } from 'vitest/config';
export default defineConfig({ test: { globals: true, include: ['.test-dist/test/**/*.e2e-spec.js'] } });
