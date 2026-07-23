use std::io;
use std::path::PathBuf;

pub struct SyncRequest {
    pub source: PathBuf,
    pub destination: PathBuf,
    pub extensions: Vec<String>,
}

pub fn sync_newer(request: &SyncRequest) -> io::Result<usize> {
    if request.extensions.is_empty()
        || request.extensions.iter().any(|extension| {
            extension.is_empty()
                || !extension
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
        })
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "sync requires safe file extensions",
        ));
    }
    if !request.source.is_dir() || !request.destination.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "sync source and destination must be directories",
        ));
    }
    let mut copied = 0;
    for entry in std::fs::read_dir(&request.source)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let source = entry.path();
        let Some(extension) = source.extension().and_then(|value| value.to_str()) else {
            continue;
        };
        if !request.extensions.iter().any(|value| value == extension) {
            continue;
        }
        let destination = request.destination.join(entry.file_name());
        if !needs_copy(&source.metadata()?, destination.metadata().ok().as_ref())? {
            continue;
        }
        portkit_core::atomic_copy(&source, &destination)?;
        copied += 1;
    }
    Ok(copied)
}

fn needs_copy(
    source: &std::fs::Metadata,
    destination: Option<&std::fs::Metadata>,
) -> io::Result<bool> {
    let Some(destination) = destination else {
        return Ok(true);
    };
    Ok(source.modified()? > destination.modified()?)
}
