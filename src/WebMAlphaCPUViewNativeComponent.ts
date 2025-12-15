import type { ViewProps } from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
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

// codegenNativeComponent uses Fabric on New Architecture
// and auto-falls back to requireNativeComponent on Legacy Architecture
export default codegenNativeComponent<NativeProps>(
  'WebMAlphaCPUView'
) as HostComponent<NativeProps>;
