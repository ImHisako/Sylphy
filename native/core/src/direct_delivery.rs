//! An application acknowledgement means the received packet was committed.
use crate::error::{CoreError, CoreResult};
use sha2::{Digest, Sha256};

const ACK_VERSION: &[u8] = b"sylphy-stored-v1:";

pub(crate) fn acknowledgement(payload: &[u8]) -> Vec<u8> {
    let mut response = ACK_VERSION.to_vec();
    response.extend_from_slice(&Sha256::digest(payload));
    response
}

pub(crate) fn confirm(expected: &[u8], response: CoreResult<Vec<u8>>) -> CoreResult<()> {
    if response? != expected {
        return Err(CoreError::NetworkAttachFailed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acknowledgement_requires_the_same_packet_and_protocol() {
        let response = acknowledgement(b"ciphertext");
        assert_eq!(acknowledgement(b"ciphertext"), response);
        assert_ne!(acknowledgement(b"other ciphertext"), response);
        assert_ne!(response, b"ok");
        assert!(!response.is_empty());
        assert!(confirm(&response, Ok(acknowledgement(b"ciphertext"))).is_ok());
        assert!(confirm(&response, Ok(acknowledgement(b"other ciphertext"))).is_err());
        assert!(confirm(&response, Ok(b"sylphy-rejected-v1".to_vec())).is_err());
        assert!(confirm(&response, Err(CoreError::NetworkAttachFailed)).is_err());
    }
}
