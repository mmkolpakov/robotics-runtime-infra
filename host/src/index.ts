export * from './compose-execution.js';
export * from './engine-metadata.js';

import {FiberState,type Fiber} from '@robotics-runtime/host';
/** Uses the official Cordis enum at TypeScript compilation, without a mirrored state value. */
export const isNativeFiberDisposed=(fiber:Pick<Fiber,'state'>):boolean=>fiber.state===FiberState.DISPOSED;
