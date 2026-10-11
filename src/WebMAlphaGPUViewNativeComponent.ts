import type { ViewProps } from 'react-native';
import { requireNativeComponent } from 'react-native';
import type { HostComponent } from 'react-native';

export interface NativeProps extends ViewProps {
  source?: {
    uri?: string;
    path?: string;
  };
  autoPlay?: boolean;
  loop?: boolean;
  paused?: boolean;
  cacheKey?: string;
}

export default requireNativeComponent<NativeProps>(
  'WebMAlphaGPUView'
) as HostComponent<NativeProps>;
