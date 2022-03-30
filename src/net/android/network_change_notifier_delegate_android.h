// Copyright (c) 2012 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef NET_ANDROID_NETWORK_CHANGE_NOTIFIER_DELEGATE_ANDROID_H_
#define NET_ANDROID_NETWORK_CHANGE_NOTIFIER_DELEGATE_ANDROID_H_

#include <atomic>
#include <map>

#include "base/android/jni_android.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/ref_counted.h"
#include "base/observer_list_threadsafe.h"
#include "base/synchronization/lock.h"
#include "base/threading/thread_checker.h"
#include "net/base/net_export.h"
#include "net/base/network_change_notifier.h"

namespace net {

// Delegate used to thread-safely notify NetworkChangeNotifierAndroid whenever a
// network connection change notification is signaled by the Java side (on the
// JNI thread).
// All the methods exposed below must be called exclusively on the JNI thread
// unless otherwise stated (e.g. RegisterObserver()/UnregisterObserver()).
class NET_EXPORT_PRIVATE NetworkChangeNotifierDelegateAndroid {
 public:
  typedef NetworkChangeNotifier::ConnectionType ConnectionType;
  typedef NetworkChangeNotifier::ConnectionSubtype ConnectionSubtype;
  typedef NetworkChangeNotifier::NetworkHandle NetworkHandle;
  typedef NetworkChangeNotifier::NetworkList NetworkList;

  // Observer interface implemented by NetworkChangeNotifierAndroid which
  // subscribes to network change notifications fired by the delegate (and
  // initiated by the Java side).
  class Observer : public NetworkChangeNotifier::NetworkObserver {
   public:
    ~Observer() override {}

    // Updates the current connection type.
    virtual void OnConnectionTypeChanged() = 0;

    // Updates the current max bandwidth.
    virtual void OnMaxBandwidthChanged(double max_bandwidth_mbps,
                                       ConnectionType connection_type) = 0;

    // Notifies that the default network has gone into a high power mode.
    virtual void OnDefaultNetworkActive() = 0;
  };

  // Initializes native (C++) side of NetworkChangeNotifierAndroid that
  // communicates with Java NetworkChangeNotifier class. The Java
  // NetworkChangeNotifier must have been previously initialized with calls
  // like this:
  //   // Creates global singleton Java NetworkChangeNotifier class instance.
  //   NetworkChangeNotifier.init();
  //   // Creates Java NetworkChangeNotifierAutoDetect class instance.
  //   NetworkChangeNotifier.registerToReceiveNotificationsAlways();
  NetworkChangeNotifierDelegateAndroid();
  NetworkChangeNotifierDelegateAndroid(
      const NetworkChangeNotifierDelegateAndroid&) = delete;
  NetworkChangeNotifierDelegateAndroid& operator=(
      const NetworkChangeNotifierDelegateAndroid&) = delete;
  ~NetworkChangeNotifierDelegateAndroid();

  // Called from NetworkChangeNotifier.java on the JNI thread whenever
  // the connection type changes. This updates the current connection type seen
  // by this class and forwards the notification to the observers that
  // subscribed through RegisterObserver().
  void NotifyConnectionTypeChanged(
      JNIEnv* env,
      const base::android::JavaParamRef<jobject>& obj,
      jint new_connection_type,
      jlong default_netid);
  jint GetConnectionType(JNIEnv* env, jobject obj) const;

  // Called from NetworkChangeNotifier.java on the JNI thread whenever
  // the maximum bandwidth of the connection changes. This updates the current
  // max bandwidth seen by this class and forwards the notification to the
  // observers that subscribed through RegisterObserver().
  void NotifyMaxBandwidthChanged(
      JNIEnv* env,
      const base::android::JavaParamRef<jobject>& obj,
      jint subtype);

  // Called from NetworkChangeNotifier.java on the JNI thread to push
  // down notifications of network connectivity events. These functions in
  // turn:
  //   1) Update |network_map_| and |default_network_|.
  //   2) Push notifications to NetworkChangeNotifier which in turn pushes
  //      notifications to its NetworkObservers. Note that these functions
  //      perform valuable transformations on the signals like deduplicating.
  // For descriptions of what individual calls mean, see
  // NetworkChangeNotifierAutoDetect.Observer functions of the same names.
  void NotifyOfNetworkConnect(JNIEnv* env,
                              const base::android::JavaParamRef<jobject>& obj,
                              jlong net_id,
                              jint connection_type);
  void NotifyOfNetworkSoonToDisconnect(
      JNIEnv* env,
      const base::android::JavaParamRef<jobject>& obj,
      jlong net_id);
  void NotifyOfNetworkDisconnect(
      JNIEnv* env,
      const base::android::JavaParamRef<jobject>& obj,
      jlong net_id);
  void NotifyPurgeActiveNetworkList(
      JNIEnv* env,
      const base::android::JavaParamRef<jobject>& obj,
      const base::android::JavaParamRef<jlongArray>& active_networks);

  // Called from NetworkActiveNotifier.java on the JNI thread to push down
  // notifications of default network going in to high power mode.
  void NotifyOfDefaultNetworkActive(JNIEnv* env);

  // Registers/unregisters the observer which receives notifications from this
  // delegate. Notifications may be dispatched to the observer from any thread.
  // |observer| must not invoke (Register|Unregister)Observer() when receiving a
  // notification, because it would cause a reentrant lock acquisition.
  // |observer| must unregister itself before
  // ~NetworkChangeNotifierDelegateAndroid().
  void RegisterObserver(Observer* observer);
  void UnregisterObserver(Observer* observer);

  // Called by NetworkChangeNotifierAndroid to report when a
  // DefaultNetworkActiveObserver has been added (or removed) so that the
  // delegate can act on that (possibly enabling or disabling default network
  // active notifications).
  void DefaultNetworkActiveObserverRemoved();
  void DefaultNetworkActiveObserverAdded();

  // These methods are simply implementations of NetworkChangeNotifier APIs of
  // the same name. They can be called from any thread.
  ConnectionType GetCurrentConnectionType() const;
  void GetCurrentMaxBandwidthAndConnectionType(
      double* max_bandwidth_mbps,
      ConnectionType* connection_type) const;
  ConnectionType GetNetworkConnectionType(NetworkHandle network) const;
  NetworkHandle GetCurrentDefaultNetwork() const;
  void GetCurrentlyConnectedNetworks(NetworkList* network_list) const;
  bool IsDefaultNetworkActive();

  // Can only be called from the main (Java) thread.
  NetworkChangeNotifier::ConnectionSubtype GetCurrentConnectionSubtype() const;

  // Returns true if NetworkCallback failed to register, indicating that
  // network-specific callbacks will not be issued.
  bool RegisterNetworkCallbackFailed() const {
    return register_network_callback_failed_;
  }

 private:
  friend class BaseNetworkChangeNotifierAndroidTest;

  // Map of active connected networks and their connection type.
  typedef std::map<NetworkHandle, ConnectionType> NetworkMap;

  // Converts a Java long[] into a NetworkMap. Expects long[] to contain
  // repeated instances of: NetworkHandle, ConnectionType
  static void JavaLongArrayToNetworkMap(
      JNIEnv* env,
      const base::android::JavaRef<jlongArray>& long_array,
      NetworkMap* network_map);

  // These can be selectively enabled/disabled as they might be expensive to
  // listen to since they could be fired often.
  void EnableDefaultNetworkActiveNotifications();
  void DisableDefaultNetworkActiveNotifications();

  // Setters that grab appropriate lock.
  void SetCurrentConnectionType(ConnectionType connection_type);
  void SetCurrentMaxBandwidth(double max_bandwidth);
  void SetCurrentDefaultNetwork(NetworkHandle default_network);
  void SetCurrentNetworksAndTypes(NetworkMap network_map);

  // Methods calling the Java side exposed for testing.
  void SetOnline();
  void SetOffline();
  void FakeNetworkConnected(NetworkHandle network, ConnectionType type);
  void FakeNetworkSoonToBeDisconnected(NetworkHandle network);
  void FakeNetworkDisconnected(NetworkHandle network);
  void FakePurgeActiveNetworkList(NetworkList networks);
  void FakeDefaultNetwork(NetworkHandle network, ConnectionType type);
  void FakeConnectionSubtypeChanged(ConnectionSubtype subtype);
  void FakeDefaultNetworkActive();

  THREAD_CHECKER(thread_checker_);

  base::Lock observer_lock_;
  raw_ptr<Observer> observer_ GUARDED_BY(observer_lock_) = nullptr;

  const base::android::ScopedJavaGlobalRef<jobject>
      java_network_change_notifier_;
  // True if NetworkCallback failed to register, indicating that
  // network-specific callbacks will not be issued.
  const bool register_network_callback_failed_;
  base::android::ScopedJavaGlobalRef<jobject> java_network_active_notifier_;
  // True if DefaultNetworkActive type of info are not supported, indicating
  // that we shouldn't try to enable its callback or query its status.
  const bool is_default_network_active_api_supported_;

  mutable base::Lock connection_lock_;  // Protects the state below.
  ConnectionType connection_type_;
  double connection_max_bandwidth_;
  NetworkHandle default_network_;
  NetworkMap network_map_;

  // Used to enable/disable default network active notifications on the Java
  // side.
  std::atomic_int default_network_active_observers_;
};

}  // namespace net

#endif  // NET_ANDROID_NETWORK_CHANGE_NOTIFIER_DELEGATE_ANDROID_H_
