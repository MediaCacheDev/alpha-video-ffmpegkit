import type { ViewProps } from 'react-native';
import { requireNativeComponent } from 'react-native';
import type { HostComponent } from 'react-native';

export interface NativeProps extends ViewProps {
  source?: {
    uri: string;
    cacheKey?: string;
  };
  autoPlay?: boolean;
  loop?: boolean;
  paused?: boolean;
  cacheKey?: string;
  verbose?: boolean;
  onLoad?: (event: { nativeEvent: { totalFrames: number; width: number; height: number } }) => void;
  onError?: (event: { nativeEvent: { error: string } }) => void;
  onEnd?: (event: { nativeEvent: {} }) => void;
}

export default requireNativeComponent<NativeProps>(
  'WebMAlphaCPUView'
) as HostComponent<NativeProps>;
