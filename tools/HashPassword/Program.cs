using Microsoft.AspNetCore.Identity;

// HashPassword — small utility to generate PBKDF2 hashes compatible with
// ASP.NET Core Identity's PasswordHasher<T>. Used to populate seed SQL.
//
// Usage:
//   dotnet run --project tools/HashPassword -- <plaintext> [<plaintext2> ...]
//   dotnet run --project tools/HashPassword -- admin demo1234

if (args.Length == 0)
{
    Console.Error.WriteLine("Usage: HashPassword <plaintext> [<plaintext2> ...]");
    return 1;
}

// Same default options the web app will use. We hash against a placeholder
// "user" object — the hasher doesn't bind the salt to any user identity.
var hasher = new PasswordHasher<object>();
var placeholder = new object();

foreach (var pw in args)
{
    var hash = hasher.HashPassword(placeholder, pw);
    Console.WriteLine($"{pw}\t{hash}");
}

return 0;
