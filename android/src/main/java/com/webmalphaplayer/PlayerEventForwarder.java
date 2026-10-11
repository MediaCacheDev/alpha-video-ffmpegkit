package com.webmalphaplayer;

import android.view.View;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.common.MapBuilder;
import com.facebook.react.uimanager.UIManagerHelper;
import com.facebook.react.uimanager.events.Event;
import com.facebook.react.uimanager.events.EventDispatcher;

import java.util.Map;

/** Turns a player view's callbacks into React events on that view. */
final class PlayerEventForwarder implements PlayerCallback {

    static Map<String, Object> exportedEvents() {
        return MapBuilder.<String, Object>builder()
            .put("onLoad", MapBuilder.of("registrationName", "onLoad"))
            .put("onError", MapBuilder.of("registrationName", "onError"))
            .put("onEnd", MapBuilder.of("registrationName", "onEnd"))
            .build();
    }

    private final View view;

    PlayerEventForwarder(View view) {
        this.view = view;
    }

    @Override
    public void onLoad(int totalFrames, int width, int height) {
        WritableMap event = Arguments.createMap();
        event.putInt("totalFrames", totalFrames);
        event.putInt("width", width);
        event.putInt("height", height);
        send("onLoad", event);
    }

    @Override
    public void onError(String error) {
        WritableMap event = Arguments.createMap();
        event.putString("error", error);
        send("onError", event);
    }

    @Override
    public void onEnd() {
        send("onEnd", Arguments.createMap());
    }

    private void send(String eventName, WritableMap params) {
        ReactContext context = (ReactContext) view.getContext();
        EventDispatcher dispatcher = UIManagerHelper.getEventDispatcherForReactTag(context, view.getId());
        if (dispatcher == null) return;
        dispatcher.dispatchEvent(new PlayerEvent(UIManagerHelper.getSurfaceId(view), view.getId(), eventName, params));
    }

    private static final class PlayerEvent extends Event<PlayerEvent> {
        private final String eventName;
        private final WritableMap eventData;

        PlayerEvent(int surfaceId, int viewTag, String eventName, WritableMap eventData) {
            super(surfaceId, viewTag);
            this.eventName = eventName;
            this.eventData = eventData;
        }

        @NonNull
        @Override
        public String getEventName() {
            return eventName;
        }

        @Override
        public boolean canCoalesce() {
            return false;
        }

        @Nullable
        @Override
        protected WritableMap getEventData() {
            return eventData;
        }
    }
}
