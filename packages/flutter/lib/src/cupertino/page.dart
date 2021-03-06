// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

const double _kMinFlingVelocity = 1.0;  // screen width per second.

// Fractional offset from offscreen to the right to fully on screen.
final FractionalOffsetTween _kRightMiddleTween = new FractionalOffsetTween(
  begin: FractionalOffset.topRight,
  end: FractionalOffset.topLeft,
);

// Fractional offset from fully on screen to 1/3 offscreen to the left.
final FractionalOffsetTween _kMiddleLeftTween = new FractionalOffsetTween(
  begin: FractionalOffset.topLeft,
  end: const FractionalOffset(-1.0/3.0, 0.0),
);

// Fractional offset from offscreen below to fully on screen.
final FractionalOffsetTween _kBottomUpTween = new FractionalOffsetTween(
  begin: FractionalOffset.bottomLeft,
  end: FractionalOffset.topLeft,
);

// BoxDecoration from no shadow to page shadow mimicking iOS page transitions.
final DecorationTween _kShadowTween = new DecorationTween(
  begin: BoxDecoration.none, // No shadow initially.
  end: const BoxDecoration(
    boxShadow: const <BoxShadow>[
      const BoxShadow(
        blurRadius: 10.0,
        spreadRadius: 4.0,
        color: const Color(0x38000000),
      ),
    ],
  ),
);

/// Provides the native iOS page transition animation.
///
/// The page slides in from the right and exits in reverse. It also shifts to the left in
/// a parallax motion when another page enters to cover it.
class CupertinoPageTransition extends StatelessWidget {
  CupertinoPageTransition({
    Key key,
    // Linear route animation from 0.0 to 1.0 when this screen is being pushed.
    @required Animation<double> primaryRouteAnimation,
    // Linear route animation from 0.0 to 1.0 when another screen is being pushed on top of this
    // one.
    @required Animation<double> secondaryRouteAnimation,
    @required this.child,
    // Perform primary transition linearly. Use to precisely track back gesture drags.
    bool linearTransition,
  }) :
      _primaryPositionAnimation = linearTransition
        ? _kRightMiddleTween.animate(primaryRouteAnimation)
        : _kRightMiddleTween.animate(
            new CurvedAnimation(
              parent: primaryRouteAnimation,
              curve: Curves.easeOut,
              reverseCurve: Curves.easeIn,
            )
          ),
      _secondaryPositionAnimation = _kMiddleLeftTween.animate(
        new CurvedAnimation(
          parent: secondaryRouteAnimation,
          curve: Curves.easeOut,
          reverseCurve: Curves.easeIn,
        )
      ),
      _primaryShadowAnimation = _kShadowTween.animate(primaryRouteAnimation),
      super(key: key);

  // When this page is coming in to cover another page.
  final Animation<FractionalOffset> _primaryPositionAnimation;
  // When this page is becoming covered by another page.
  final Animation<FractionalOffset> _secondaryPositionAnimation;
  final Animation<Decoration> _primaryShadowAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // TODO(ianh): tell the transform to be un-transformed for hit testing
    // but not while being controlled by a gesture.
    return new SlideTransition(
      position: _secondaryPositionAnimation,
      child: new SlideTransition(
        position: _primaryPositionAnimation,
        child: new DecoratedBoxTransition(
          decoration: _primaryShadowAnimation,
          child: child,
        ),
      ),
    );
  }
}

/// Transitions used for summoning fullscreen dialogs in iOS such as creating a new
/// calendar event etc by bringing in the next screen from the bottom.
class CupertinoFullscreenDialogTransition extends StatelessWidget {
  CupertinoFullscreenDialogTransition({
    Key key,
    @required Animation<double> animation,
    @required this.child,
  }) : _positionAnimation = _kBottomUpTween.animate(
         new CurvedAnimation(
           parent: animation,
           curve: Curves.easeInOut,
         )
       ),
       super(key: key);

  final Animation<FractionalOffset> _positionAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return new SlideTransition(
      position: _positionAnimation,
      child: child,
    );
  }
}

/// This class responds to drag gestures to control the route's transition
/// animation progress. Used for iOS back gesture.
class CupertinoBackGestureController extends NavigationGestureController {
  CupertinoBackGestureController({
    @required NavigatorState navigator,
    @required this.controller,
  }) : super(navigator) {
    assert(controller != null);
  }

  final AnimationController controller;

  @override
  void dispose() {
    controller.removeStatusListener(_handleStatusChanged);
    super.dispose();
  }

  @override
  void dragUpdate(double delta) {
    // This assert can be triggered the Scaffold is reparented out of the route
    // associated with this gesture controller and continues to feed it events.
    // TODO(abarth): Change the ownership of the gesture controller so that the
    // object feeding it these events (e.g., the Scaffold) is responsible for
    // calling dispose on it as well.
    assert(controller != null);
    controller.value -= delta;
  }

  @override
  bool dragEnd(double velocity) {
    // This assert can be triggered the Scaffold is reparented out of the route
    // associated with this gesture controller and continues to feed it events.
    // TODO(abarth): Change the ownership of the gesture controller so that the
    // object feeding it these events (e.g., the Scaffold) is responsible for
    // calling dispose on it as well.
    assert(controller != null);

    if (velocity.abs() >= _kMinFlingVelocity) {
      controller.fling(velocity: -velocity);
    } else if (controller.value <= 0.5) {
      controller.fling(velocity: -1.0);
    } else {
      controller.fling(velocity: 1.0);
    }

    // Don't end the gesture until the transition completes.
    final AnimationStatus status = controller.status;
    _handleStatusChanged(status);
    controller?.addStatusListener(_handleStatusChanged);

    return (status == AnimationStatus.reverse || status == AnimationStatus.dismissed);
  }

  void _handleStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed)
      navigator.pop();
  }
}
