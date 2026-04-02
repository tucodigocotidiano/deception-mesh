use anyhow::{anyhow, Result};
use argon2::{
    password_hash::{PasswordHasher, SaltString},
    Argon2,
};
use clap::Parser;
use rand::thread_rng;

#[derive(Debug, Parser)]
struct Args {
    #[arg(long)]
    password: String,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let salt = SaltString::generate(&mut thread_rng());

    let hash = Argon2::default()
        .hash_password(args.password.as_bytes(), &salt)
        .map_err(|e| anyhow!("argon2 hash_password failed: {e:?}"))?
        .to_string();

    println!("{hash}");
    Ok(())
}
