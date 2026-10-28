#[cfg(feature = "webrtc")]
use crate::webrtc::{self, is_webrtc_endpoint};
use crate::{
    config::{Config, NetworkType},
    tcp::FramedStream,
    udp::FramedSocket,
    websocket::{self, check_ws, is_ws_endpoint},
    ResultType, Stream,
};
use anyhow::Context;
use std::{net::SocketAddr, sync::Arc};
use tokio::net::{ToSocketAddrs, UdpSocket};
use tokio_socks::{IntoTargetAddr, TargetAddr};

#[inline]
pub fn check_port<T: std::string::ToString>(host: T, port: i32) -> String {
    let host = host.to_string();
    if crate::is_ipv6_str(&host) {
        if host.starts_with('[') {
            return host;
        }
        return format!("[{host}]:{port}");
    }
    if !host.contains(':') {
        return format!("{host}:{port}");
    }
    host
}

#[inline]
pub fn increase_port<T: std::string::ToString>(host: T, offset: i32) -> String {
    let host = host.to_string();
    if crate::is_ipv6_str(&host) {
        if host.starts_with('[') {
            let tmp: Vec<&str> = host.split("]:").collect();
            if tmp.len() == 2 {
                let port: i32 = tmp[1].parse().unwrap_or(0);
                if port > 0 {
                    return format!("{}]:{}", tmp[0], port + offset);
                }
            }
        }
    } else if host.contains(':') {
        let tmp: Vec<&str> = host.split(':').collect();
        if tmp.len() == 2 {
            let port: i32 = tmp[1].parse().unwrap_or(0);
            if port > 0 {
                return format!("{}:{}", tmp[0], port + offset);
            }
        }
    }
    host
}

pub fn split_host_port<T: std::string::ToString>(host: T) -> Option<(String, i32)> {
    let host = host.to_string();
    if crate::is_ipv6_str(&host) {
        if host.starts_with('[') {
            let tmp: Vec<&str> = host.split("]:").collect();
            if tmp.len() == 2 {
                let port: i32 = tmp[1].parse().unwrap_or(0);
                if port > 0 {
                    return Some((format!("{}]", tmp[0]), port));
                }
            }
        }
    } else if host.contains(':') {
        let tmp: Vec<&str> = host.split(':').collect();
        if tmp.len() == 2 {
            let port: i32 = tmp[1].parse().unwrap_or(0);
            if port > 0 {
                return Some((tmp[0].to_string(), port));
            }
        }
    }
    None
}

pub fn test_if_valid_server(host: &str, test_with_proxy: bool) -> String {
    let host = check_port(host, 0);
    use std::net::ToSocketAddrs;

    if test_with_proxy && NetworkType::ProxySocks == Config::get_network_type() {
        test_if_valid_server_for_proxy_(&host)
    } else {
        match host.to_socket_addrs() {
            Err(err) => err.to_string(),
            Ok(_) => "".to_owned(),
        }
    }
}

#[inline]
pub fn test_if_valid_server_for_proxy_(host: &str) -> String {
    // `&host.into_target_addr()` is defined in `tokio-socs`, but is a common pattern for testing,
    // it can be used for both `socks` and `http` proxy.
    match &host.into_target_addr() {
        Err(err) => err.to_string(),
        Ok(_) => "".to_owned(),
    }
}

pub trait IsResolvedSocketAddr {
    fn resolve(&self) -> Option<&SocketAddr>;
}

impl IsResolvedSocketAddr for SocketAddr {
    fn resolve(&self) -> Option<&SocketAddr> {
        Some(self)
    }
}

impl IsResolvedSocketAddr for String {
    fn resolve(&self) -> Option<&SocketAddr> {
        None
    }
}

impl IsResolvedSocketAddr for &str {
    fn resolve(&self) -> Option<&SocketAddr> {
        None
    }
}

// This function checks if the target is a websocket endpoint and connects accordingly.
#[inline]
pub async fn connect_tcp<
    't,
    T: IntoTargetAddr<'t> + ToSocketAddrs + IsResolvedSocketAddr + std::fmt::Display,
>(
    target: T,
    ms_timeout: u64,
) -> ResultType<crate::Stream> {
    #[cfg(feature = "webrtc")]
    if is_webrtc_endpoint(&target.to_string()) {
        return Ok(Stream::WebRTC(
            webrtc::WebRTCStream::new(&target.to_string(), false, ms_timeout).await?,
        ));
    }
    let target_str = check_ws(&target.to_string());
    if is_ws_endpoint(&target_str) {
        return Ok(Stream::WebSocket(
            websocket::WsFramedStream::new(target_str, None, ms_timeout).await?,
        ));
    }
    connect_tcp_local(target, None, ms_timeout).await
}

// This function connects directly to the target without checking for websocket endpoints.
pub async fn connect_tcp_local<
    't,
    T: IntoTargetAddr<'t> + ToSocketAddrs + IsResolvedSocketAddr + std::fmt::Display,
>(
    target: T,
    local: Option<SocketAddr>,
    ms_timeout: u64,
) -> ResultType<Stream> {
    if let Some(conf) = Config::get_socks() {
        return Ok(Stream::Tcp(
            FramedStream::connect(target, local, &conf, ms_timeout).await?,
        ));
    }

    if let Some(target_addr) = target.resolve() {
        if let Some(local_addr) = local {
            if local_addr.is_ipv6() && target_addr.is_ipv4() {
                let resolved_target = query_nip_io(target_addr).await?;
                return Ok(Stream::Tcp(
                    FramedStream::new(resolved_target, Some(local_addr), ms_timeout).await?,
                ));
            }
        }
    }

    Ok(Stream::Tcp(
        FramedStream::new(target, local, ms_timeout).await?,
    ))
}

#[inline]
pub fn is_ipv4(target: &TargetAddr<'_>) -> bool {
    match target {
        TargetAddr::Ip(addr) => addr.is_ipv4(),
        _ => true,
    }
}

#[inline]
pub async fn query_nip_io(addr: &SocketAddr) -> ResultType<SocketAddr> {
    tokio::net::lookup_host(format!("{}.nip.io:{}", addr.ip(), addr.port()))
        .await?
        .find(|x| x.is_ipv6())
        .context("Failed to get ipv6 from nip.io")
}

#[inline]
pub fn ipv4_to_ipv6(addr: String, ipv4: bool) -> String {
    if !ipv4 && crate::is_ipv4_str(&addr) {
        if let Some(ip) = addr.split(':').next() {
            return addr.replace(ip, &format!("{ip}.nip.io"));
        }
    }
    addr
}

/// The addresses to try for a relay, in the order they should be tried.
///
/// The nip.io form of an IPv4 literal is the mapped IPv6 address of that literal, and
/// reaching it costs a lookup of a name that exists only to be looked up. That lookup is
/// answered by a public resolver, so on a network with no route to one — the intranet of
/// a site whose own server holds the relay — it cannot be answered, and a relay that is
/// right there stays unreachable.
///
/// So the literal is offered as well: it needs no resolver at all, and a network that
/// can answer the mapped name simply reaches it first, exactly as before. Both are tried
/// in turn, and the first that opens wins.
#[inline]
pub fn relay_addresses(addr: String, ipv4: bool) -> Vec<String> {
    let mapped = if !ipv4 && crate::is_ipv4_str(&addr) {
        addr.split(':').next().map(|ip| addr.replace(ip, &format!("{ip}.nip.io")))
    } else {
        None
    };
    match mapped {
        Some(mapped) => vec![mapped, addr],
        None => vec![addr],
    }
}
/// The resolver's preferred address for `target`: first in getaddrinfo's RFC 6724 order, so NAT64's
/// synthesized IPv6 leads on a v6-only host. Preferred, not proven reachable: what `test_target`
/// falls back to, and what the controller's NAT test takes as is to spare itself the proof.
///
/// The first candidate is taken, but a host that resolves to both families is resolved the way
/// the machine can actually use: an address of the family the local socket was opened in is
/// preferred over the other. The resolver's order is a statement about the host, not about this
/// machine, and a host that answers on IPv4 while the resolver lists an IPv6 first would send
/// the probe — and the connection that follows it — to an address this host has no route to.
async fn resolve_target(target: &str) -> ResultType<SocketAddr> {
    let addrs = tokio::net::lookup_host(target)
        .await?
        .collect::<Vec<_>>();
    let first = *addrs
        .first()
        .context(format!("Failed to look up host for {target}"))?;
    if addrs.len() == 1 {
        return Ok(first);
    }
    // The family that can be reached is the one the local stack offers, which the caller
    // opens a socket in. A host on the same network as this one usually answers on IPv4
    // while its AAAA still resolves, and taking the AAAA would point the probe — and the
    // connection that follows it — at an address this host has no route to.
    if first.is_ipv4() {
        return Ok(first);
    }
    if let Some(v4) = addrs.iter().find(|a| a.is_ipv4()) {
        return Ok(*v4);
    }
    Ok(first)
}

/// The address of `target` a TCP connection reaches, the resolver's candidates tried in order until
/// one answers: an AAAA the server refuses is passed over for its A record, which the order alone
/// would not do. For the rendezvous registration and the punch reply, which live on what it picks.
async fn test_target(target: &str) -> ResultType<SocketAddr> {
    if let Ok(Ok(s)) = super::timeout(1000, tokio::net::TcpStream::connect(target)).await {
        if let Ok(addr) = s.peer_addr() {
            return Ok(addr);
        }
    }
    resolve_target(target).await
}

#[inline]
pub async fn new_direct_udp_for(target: &str) -> ResultType<(Arc<UdpSocket>, SocketAddr)> {
    let peer_addr = test_target(target).await?;
    let local_addr = Config::get_any_listen_addr(peer_addr.is_ipv4());
    let socket = UdpSocket::bind(local_addr).await?;
    Ok((Arc::new(socket), peer_addr))
}

/// `new_direct_udp_for` on the resolver's preferred address, with no handshake to prove it and a
/// second at most for the lookup: for the controller's NAT test, once per connection, where the
/// proof cost a round trip right before the connection it then opens to the same host.
#[inline]
pub async fn new_direct_udp_for_unverified(
    target: &str,
) -> ResultType<(Arc<UdpSocket>, SocketAddr)> {
    let peer_addr = super::timeout(1000, resolve_target(target)).await??;
    let local_addr = Config::get_any_listen_addr(peer_addr.is_ipv4());
    let socket = UdpSocket::bind(local_addr).await?;
    Ok((Arc::new(socket), peer_addr))
}

#[inline]
pub async fn new_udp_for(
    target: &str,
    ms_timeout: u64,
) -> ResultType<(FramedSocket, TargetAddr<'static>)> {
    let (ipv4, target) = if NetworkType::Direct == Config::get_network_type() {
        let addr = test_target(target).await?;
        (addr.is_ipv4(), addr.into_target_addr()?)
    } else {
        (true, target.into_target_addr()?)
    };
    Ok((
        new_udp(Config::get_any_listen_addr(ipv4), ms_timeout).await?,
        target.to_owned(),
    ))
}

async fn new_udp<T: ToSocketAddrs>(local: T, ms_timeout: u64) -> ResultType<FramedSocket> {
    match Config::get_socks() {
        None => Ok(FramedSocket::new(local).await?),
        Some(conf) => {
            let socket = FramedSocket::new_proxy(
                conf.proxy.as_str(),
                local,
                conf.username.as_str(),
                conf.password.as_str(),
                ms_timeout,
            )
            .await?;
            Ok(socket)
        }
    }
}

pub async fn rebind_udp_for(
    target: &str,
) -> ResultType<Option<(FramedSocket, TargetAddr<'static>)>> {
    if Config::get_network_type() != NetworkType::Direct {
        return Ok(None);
    }
    let addr = test_target(target).await?;
    let v4 = addr.is_ipv4();
    Ok(Some((
        FramedSocket::new(Config::get_any_listen_addr(v4)).await?,
        addr.into_target_addr()?.to_owned(),
    )))
}

#[cfg(test)]
mod tests {
    use std::net::ToSocketAddrs;

    use super::*;

    #[test]
    fn test_nat64() {
        test_nat64_async();
    }

    /// The relay is dialled at the address it is given, and the mapped form of an IPv4
    /// literal needs a resolver that can answer for it. Both are offered so a network
    /// without a public resolver still reaches the relay.
    #[test]
    fn relay_addresses_offers_the_literal_beside_the_mapped_name() {
        assert_eq!(
            relay_addresses("1.2.3.4:21117".to_owned(), false),
            vec!["1.2.3.4.nip.io:21117".to_owned(), "1.2.3.4:21117".to_owned()]
        );
        assert_eq!(
            relay_addresses("1.2.3.4:21117".to_owned(), true),
            vec!["1.2.3.4:21117".to_owned()]
        );
        // A name is already whatever the resolver has to answer, so it is offered once.
        assert_eq!(
            relay_addresses("rustdesk.com:21117".to_owned(), false),
            vec!["rustdesk.com:21117".to_owned()]
        );
    }

    #[tokio::main(flavor = "current_thread")]
    async fn test_nat64_async() {
        assert_eq!(ipv4_to_ipv6("1.1.1.1".to_owned(), true), "1.1.1.1");
        assert_eq!(ipv4_to_ipv6("1.1.1.1".to_owned(), false), "1.1.1.1.nip.io");
        assert_eq!(
            ipv4_to_ipv6("1.1.1.1:8080".to_owned(), false),
            "1.1.1.1.nip.io:8080"
        );
        assert_eq!(
            ipv4_to_ipv6("rustdesk.com".to_owned(), false),
            "rustdesk.com"
        );
        if ("rustdesk.com:80")
            .to_socket_addrs()
            .unwrap()
            .next()
            .unwrap()
            .is_ipv6()
        {
            assert!(query_nip_io(&"1.1.1.1:80".parse().unwrap())
                .await
                .unwrap()
                .is_ipv6());
            return;
        }
        assert!(query_nip_io(&"1.1.1.1:80".parse().unwrap()).await.is_err());
    }

    #[test]
    fn test_test_if_valid_server() {
        assert!(!test_if_valid_server("a", false).is_empty());
        // on Linux, "1" is resolved to "0.0.0.1"
        assert!(test_if_valid_server("1.1.1.1", false).is_empty());
        assert!(test_if_valid_server("1.1.1.1:1", false).is_empty());
        assert!(test_if_valid_server("microsoft.com", false).is_empty());
        assert!(test_if_valid_server("microsoft.com:1", false).is_empty());

        // with proxy
        // `:0` indicates `let host = check_port(host, 0);` is called.
        assert!(test_if_valid_server_for_proxy_("a:0").is_empty());
        assert!(test_if_valid_server_for_proxy_("1.1.1.1:0").is_empty());
        assert!(test_if_valid_server_for_proxy_("1.1.1.1:1").is_empty());
        assert!(test_if_valid_server_for_proxy_("abc.com:0").is_empty());
        assert!(test_if_valid_server_for_proxy_("abcd.com:1").is_empty());
    }

    #[test]
    fn test_check_port() {
        assert_eq!(check_port("[1:2]:12", 32), "[1:2]:12");
        assert_eq!(check_port("1:2", 32), "[1:2]:32");
        assert_eq!(check_port("z1:2", 32), "z1:2");
        assert_eq!(check_port("1.1.1.1", 32), "1.1.1.1:32");
        assert_eq!(check_port("1.1.1.1:32", 32), "1.1.1.1:32");
        assert_eq!(check_port("test.com:32", 0), "test.com:32");
        assert_eq!(increase_port("[1:2]:12", 1), "[1:2]:13");
        assert_eq!(increase_port("1.2.2.4:12", 1), "1.2.2.4:13");
        assert_eq!(increase_port("1.2.2.4", 1), "1.2.2.4");
        assert_eq!(increase_port("test.com", 1), "test.com");
        assert_eq!(increase_port("test.com:13", 4), "test.com:17");
        assert_eq!(increase_port("1:13", 4), "1:13");
        assert_eq!(increase_port("22:1:13", 4), "22:1:13");
        assert_eq!(increase_port("z1:2", 1), "z1:3");
    }
}
