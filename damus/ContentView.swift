//
//  ContentView.swift
//  damus
//
//  Created by William Casarin on 2022-04-01.
//

import SwiftUI
import Starscream

struct TimestampedProfile {
    let profile: Profile
    let timestamp: Int64
}

enum Sheets: Identifiable {
    case post

    var id: String {
        switch self {
        case .post:
            return "post"
        }
    }
}

enum Timeline: String, CustomStringConvertible {
    case home
    case notifications
    
    var description: String {
        return self.rawValue
    }
}

struct ContentView: View {
    @State var status: String = "Not connected"
    @State var active_sheet: Sheets? = nil
    @State var profiles: Profiles = Profiles()
    @State var friends: [String: ()] = [:]
    @State var loading: Bool = true
    @State var pool: RelayPool? = nil
    @State var selected_timeline: Timeline? = .home
    @State var last_event_of_kind: [Int: NostrEvent] = [:]
    @State var has_events: [String: ()] = [:]
    @State var notifications_active: Bool = false
    @State var new_notifications: Bool = false
    
    @State var events: [NostrEvent] = []
    @State var notifications: [NostrEvent] = []
    
    // connect retry timer
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    let sub_id = UUID().description
    let pubkey = "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245"
    
    var NotificationTab: some View {
        ZStack(alignment: .center) {
            Button(action: {switch_timeline(.notifications)}) {
                Label("", systemImage: selected_timeline == .notifications ? "bell.fill" : "bell")
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, minHeight: 30.0)
            }
            .foregroundColor(selected_timeline != .notifications ? .gray : .primary)
            
            if new_notifications {
                Circle()
                    .size(CGSize(width: 8, height: 8))
                    .frame(width: 10, height: 10, alignment: .topTrailing)
                    .alignmentGuide(VerticalAlignment.center) { a in a.height + 2.0 }
                    .alignmentGuide(HorizontalAlignment.center) { a in a.width - 12.0 }
                    .foregroundColor(.accentColor)
            }
        }
    }
    
    var HomeTab: some View {
        Button(action: {switch_timeline(.home)}) {
            Label("", systemImage: selected_timeline == .home ? "house.fill" : "house")
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, minHeight: 30.0)
        }
        .foregroundColor(selected_timeline != .home ? .gray : .primary)
    }
    
    var TabBar: some View {
        VStack {
            Divider()
            HStack {
                HomeTab
                NotificationTab
            }
        }
    }

    var LoadingContainer: some View {
        VStack {
            HStack {
                Spacer()
        
                if self.loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }

            Spacer()
        }
    }

    var PostButtonContainer: some View {
        VStack {
            
            Spacer()

            HStack {
                Spacer()
                PostButton() {
                    self.active_sheet = .post
                }
            }
        }
    }
    
    var PostingTimelineView: some View {
        ZStack {
            if let pool = self.pool {
                TimelineView(events: $events, pool: pool)
                    .environmentObject(profiles)
            }
            PostButtonContainer
        }
    }
    
    var body: some View {
        VStack {
            if let pool = self.pool {
                ZStack {
                    NavigationView {
                        VStack {
                            PostingTimelineView
                                .onAppear() {
                                    switch_timeline(.home)
                                }
                            
                                let tlv = TimelineView(events: $notifications, pool: pool)
                                    .environmentObject(profiles)
                                    .navigationTitle("Notifications")
                                    .navigationBarBackButtonHidden(true)
                            
                                NavigationLink(destination: tlv, isActive: $notifications_active) {
                                    EmptyView()
                                }
                        }
                        .navigationBarTitle("Damus", displayMode: .inline)
                    }
                    .padding([.bottom], -8.0)

                    LoadingContainer
                }
            }
            
            TabBar
        }
        .onAppear() {
            self.connect()
        }
        .sheet(item: $active_sheet) { item in
            switch item {
            case .post:
                PostView(references: [])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .post)) { obj in
            let post = obj.object as! NostrPost
            print("post \(post.content)")
            let privkey = ""
            let new_ev = post.to_event(privkey: privkey, pubkey: pubkey)
            self.pool?.send(.event(new_ev))
        }
        .onReceive(timer) { n in
            self.pool?.connect_to_disconnected()
            self.loading = (self.pool?.num_connecting ?? 0) != 0
        }
    }

    func is_friend(_ pubkey: String) -> Bool {
        return pubkey == self.pubkey || self.friends[pubkey] != nil
    }

    func switch_timeline(_ timeline: Timeline) {
        if timeline == .notifications {
            self.notifications_active = true
            self.selected_timeline = .notifications
            new_notifications = false
        } else {
            self.notifications_active = false
            self.selected_timeline = .home
        }
        //self.selected_timeline = timeline
    }

    func add_relay(_ pool: RelayPool, _ relay: String) {
        //add_rw_relay(pool, "wss://nostr-pub.wellorder.net")
        let wssrelay = "wss://\(relay)"
        add_rw_relay(pool, wssrelay)
        let profile = Profile(name: relay, about: nil, picture: nil)
        let ts = Int64(Date().timeIntervalSince1970)
        let tsprofile = TimestampedProfile(profile: profile, timestamp: ts)
        self.profiles.add(id: wssrelay, profile: tsprofile)
    }

    func connect() {
        let pool = RelayPool()

        add_relay(pool, "nostr-pub.wellorder.net")
        add_relay(pool, "nostr.onsats.org")
        add_relay(pool, "nostr.bitcoiner.social")
        add_relay(pool, "nostr-relay.freeberty.net")
        add_relay(pool, "nostr-relay.untethr.me")

        pool.register_handler(sub_id: sub_id, handler: handle_event)

        self.pool = pool
        pool.connect()
    }

    func handle_contact_event(_ ev: NostrEvent) {
        if ev.pubkey == self.pubkey {
            // our contacts
            for tag in ev.tags {
                if tag.count > 1 && tag[0] == "p" {
                    self.friends[tag[1]] = ()
                }
            }
        }
    }

    func handle_metadata_event(_ ev: NostrEvent) {
        guard let profile: Profile = decode_data(Data(ev.content.utf8)) else {
            return
        }

        if let mprof = self.profiles.lookup_with_timestamp(id: ev.pubkey) {
            if mprof.timestamp > ev.created_at {
                // skip if we already have an newer profile
                return
            }
        }

        let tprof = TimestampedProfile(profile: profile, timestamp: ev.created_at)
        self.profiles.add(id: ev.pubkey, profile: tprof)
    }

    func send_filters(relay_id: String) {
        // TODO: since times should be based on events from a specific relay
        // perhaps we could mark this in the relay pool somehow

        let last_text_event = last_event_of_kind[NostrKind.text.rawValue]
        let since = get_since_time(last_event: last_text_event)
        var since_filter = NostrFilter.filter_text
        since_filter.since = since

        let last_metadata_event = last_event_of_kind[NostrKind.metadata.rawValue]
        var profile_filter = NostrFilter.filter_profiles
        if let prof_since = get_metadata_since_time(last_metadata_event) {
            profile_filter.since = prof_since
        }
        
        /*
        var notification_filter = NostrFilter.filter_text
        notification_filter.since = since
         */

        var contacts_filter = NostrFilter.filter_contacts
        contacts_filter.authors = [self.pubkey]

        let filters = [since_filter, profile_filter, contacts_filter]
        print("connected to \(relay_id), refreshing from \(since)")
        self.pool?.send(.subscribe(.init(filters: filters, sub_id: sub_id)))
        //self.pool?.send(.subscribe(.init(filters: [notification_filter], sub_id: "notifications")))
    }
    
    func handle_notification(ev: NostrEvent) {
        notifications.append(ev)
        notifications = notifications.sorted { $0.created_at > $1.created_at }
        
        let last_notified = get_last_notified()
        
        if last_notified == nil || last_notified!.created_at < ev.created_at {
            save_last_notified(ev)
            new_notifications = true
        }
    }
    
    func process_event(_ ev: NostrEvent) {
        if has_events[ev.id] == nil {
            has_events[ev.id] = ()
            let last_k = last_event_of_kind[ev.kind]
            if last_k == nil || ev.created_at > last_k!.created_at {
                last_event_of_kind[ev.kind] = ev
            }
            if ev.kind == 1 {
                if !should_hide_event(ev) {
                    self.events.append(ev)
                    self.events = self.events.sorted { $0.created_at > $1.created_at }
                    
                    if is_notification(ev: ev, pubkey: pubkey) {
                        handle_notification(ev: ev)
                    }
                }
            } else if ev.kind == 0 {
                handle_metadata_event(ev)
            } else if ev.kind == 3 {
                handle_contact_event(ev)
            }
        }
    }
    
    func handle_event(relay_id: String, conn_event: NostrConnectionEvent) {
        switch conn_event {
        case .ws_event(let ev):

            /*
            if let wsev = ws_nostr_event(relay: relay_id, ev: ev) {
                wsev.flags |= 1
                self.events.insert(wsev, at: 0)
            }
             */
            

            switch ev {
            case .connected:
                send_filters(relay_id: relay_id)
            case .error(let merr):
                let desc = merr.debugDescription
                if desc.contains("Software caused connection abort") {
                    self.pool?.reconnect(to: [relay_id])
                }
            case .disconnected: fallthrough
            case .cancelled:
                self.pool?.reconnect(to: [relay_id])
            case .reconnectSuggested(let t):
                if t {
                    self.pool?.reconnect(to: [relay_id])
                }
            default:
                break
            }
            
            self.loading = (self.pool?.num_connecting ?? 0) != 0

            print("ws_event \(ev)")

        case .nostr_event(let ev):
            switch ev {
            case .event(let sub_id, let ev):
                if sub_id != self.sub_id {
                    // TODO: other views like threads might have their own sub ids, so ignore those events... or should we?
                    return
                }
                
                self.process_event(ev)
            case .notice(let msg):
                self.events.insert(NostrEvent(content: "NOTICE from \(relay_id): \(msg)", pubkey: "system"), at: 0)
                print(msg)
            }
        }
    }

    func should_hide_event(_ ev: NostrEvent) -> Bool {
        // TODO: implement mute
        if ev.pubkey == "887645fef0ce0c3c1218d2f5d8e6132a19304cdc57cd20281d082f38cfea0072" {
            return true
        }
        return false
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


func get_metadata_since_time(_ metadata_event: NostrEvent?) -> Int64? {
    if metadata_event == nil {
        return nil
    }

    return metadata_event!.created_at - 60 * 10
}

func get_since_time(last_event: NostrEvent?) -> Int64 {
    if last_event == nil {
        return Int64(Date().timeIntervalSince1970) - (24 * 60 * 60 * 4)
    }

    return last_event!.created_at - 60 * 10
}

/*
func fetch_profiles(relay: URL, pubkeys: [String]) {
    return NostrFilter(ids: nil, kinds: 3, event_ids: nil, pubkeys: pubkeys, since: nil, until: nil, authors: pubkeys)
}


func nostr_req(relays: [URL], filter: NostrFilter) {
    if relays.count == 0 {
        return
    }
    let conn = NostrConnection(url: relay) {
    }
}


func get_profiles()

*/


func ws_nostr_event(relay: String, ev: WebSocketEvent) -> NostrEvent? {
    switch ev {
    case .binary(let dat):
        return NostrEvent(content: "binary data? \(dat.count) bytes", pubkey: relay)
    case .cancelled:
        return NostrEvent(content: "cancelled", pubkey: relay)
    case .connected:
        return NostrEvent(content: "connected", pubkey: relay)
    case .disconnected:
        return NostrEvent(content: "disconnected", pubkey: relay)
    case .error(let err):
        return NostrEvent(content: "error \(err.debugDescription)", pubkey: relay)
    case .text(let txt):
        return NostrEvent(content: "text \(txt)", pubkey: relay)
    case .pong:
        return NostrEvent(content: "pong", pubkey: relay)
    case .ping:
        return NostrEvent(content: "ping", pubkey: relay)
    case .viabilityChanged(let b):
        return NostrEvent(content: "viabilityChanged \(b)", pubkey: relay)
    case .reconnectSuggested(let b):
        return NostrEvent(content: "reconnectSuggested \(b)", pubkey: relay)
    }
}

func is_notification(ev: NostrEvent, pubkey: String) -> Bool {
    if ev.pubkey == pubkey {
        return false
    }
    return ev.references(id: pubkey, key: "p")
}


extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return viewControllers.count > 1
    }
}

struct LastNotification {
    let id: String
    let created_at: Int64
}

func get_last_notified() -> LastNotification? {
    let last = UserDefaults.standard.string(forKey: "last_notification")
    let last_created = UserDefaults.standard.string(forKey: "last_notification_time")
        .flatMap { Int64($0) }
    
    return last.flatMap { id in
        last_created.map { created in
            return LastNotification(id: id, created_at: created)
        }
    }
}

func save_last_notified(_ ev: NostrEvent) {
    UserDefaults.standard.set(ev.id, forKey: "last_notification")
    UserDefaults.standard.set(String(ev.created_at), forKey: "last_notification_time")
}
