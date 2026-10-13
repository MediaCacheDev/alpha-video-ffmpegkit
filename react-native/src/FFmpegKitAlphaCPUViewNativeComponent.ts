import type * as React from 'react';
import type { HostComponent, ViewProps } from 'react-native';
import type {
  DirectEventHandler,
  Double,
  Int32,
  WithDefault,
} from 'react-native/Libraries/Types/CodegenTypes';
import codegenNativeCommands from 'react-native/Libraries/Utilities/codegenNativeCommands';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

// The GPU and CPU specs are the same; codegen needs each one's types in its own file.

type LoadEvent = Readonly<{
  totalFrames: Int32;
  width: Int32;
  height: Int32;
}>;

type ErrorEvent = Readonly<{
  error: string;
}>;

export interface NativeProps extends ViewProps {
  source?: Readonly<{
    uri?: string;
    cacheKey?: string;
  }>;
  autoPlay?: WithDefault<boolean, true>;
  loop?: WithDefault<boolean, true>;
  paused?: WithDefault<boolean, false>;
  cacheKey?: string;
  verbose?: WithDefault<boolean, false>;
  mode?: WithDefault<'stream' | 'preload', 'stream'>;
  streamBufferFrames?: WithDefault<Int32, 15>;
  onLoad?: DirectEventHandler<LoadEvent>;
  onError?: DirectEventHandler<ErrorEvent>;
  onEnd?: DirectEventHandler<Readonly<{}>>;
}

type NativeComponentType = HostComponent<NativeProps>;

interface NativeCommands {
  seekToFrame: (viewRef: React.ElementRef<NativeComponentType>, frame: Int32) => void;
  seekToTime: (viewRef: React.ElementRef<NativeComponentType>, seconds: Double) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['seekToFrame', 'seekToTime'],
});

export default codegenNativeComponent<NativeProps>('RNFFmpegKitAlphaCPUView') as NativeComponentType;
