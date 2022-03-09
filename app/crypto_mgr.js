const crypto = require('crypto');

var resizedIV = Buffer.allocUnsafe(16);
var iv = crypto.createHash("sha256").update("anystring").digest();
iv.copy(resizedIV);


function Encrypt(symKey, plainText) {

    const key = crypto.createHash("sha256").update(symKey).digest();
    const cipher = crypto.createCipheriv("aes256", key, resizedIV);
    var encoded = cipher.update(plainText, "utf8", 'base64');
    encoded += cipher.final('base64');
    return encoded;
}
module.exports.Encrypt = Encrypt;

function Decrypt(symKey, encoded) {
    // console.log(`Decrypt ${encoded} with key ${symKey}`);
    const key = crypto.createHash("sha256").update(symKey).digest();
    const decipher = crypto.createDecipheriv("aes256", key, resizedIV);
    var decoded = decipher.update(encoded, "base64","utf8");
    decoded += decipher.final("utf8");
    return decoded;
}
module.exports.Decrypt = Decrypt;

function CreateKey() {
    return Math.random().toString(36).substring(6);
}

module.exports.CreateKey = CreateKey;

function PublicEncrypt(pubKey, plainText) {
    return  crypto.publicEncrypt(pubKey, Buffer.from(plainText));
}
module.exports.PublicEncrypt = PublicEncrypt;

function PrivateDecrypt(privKey, passpharse, encryptedData) {
    return crypto.privateDecrypt({key: privKey, passphrase: passpharse}, encryptedData).toString("utf-8");
}
module.exports.PrivateDecrypt = PrivateDecrypt;

function HashOp(text) {
    return crypto.createHash("sha256").update(text).digest("hex");
}
module.exports.HashOp = HashOp;

function CreateSalt() {
    return Math.random().toString(36).substring(4);
}
module.exports.CreateSalt = CreateSalt;
