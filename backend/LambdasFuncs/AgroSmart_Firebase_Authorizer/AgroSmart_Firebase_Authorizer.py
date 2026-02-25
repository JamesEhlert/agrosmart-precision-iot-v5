import { createRemoteJWKSet, jwtVerify } from "jose";

/**
 * Firebase ID Token verification:
 * - issuer: https://securetoken.google.com/<PROJECT_ID>
 * - audience: <PROJECT_ID>
 */
const PROJECT_ID = process.env.FIREBASE_PROJECT_ID;
const ISSUER = PROJECT_ID ? `https://securetoken.google.com/${PROJECT_ID}` : null;

// Endpoint JWKS (JWK Set) para tokens do Firebase
const JWKS_URL = new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com");
const JWKS = createRemoteJWKSet(JWKS_URL);

function policy(effect, methodArn, principalId, context = {}) {
  return {
    principalId,
    policyDocument: {
      Version: "2012-10-17",
      Statement: [
        { Action: "execute-api:Invoke", Effect: effect, Resource: methodArn },
      ],
    },
    context,
  };
}

export const handler = async (event) => {
  try {
    if (!PROJECT_ID) {
      console.log("Missing FIREBASE_PROJECT_ID env var");
      throw new Error("Unauthorized");
    }

    const auth = event.authorizationToken || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : auth.trim();

    if (!token) throw new Error("Unauthorized");

    const { payload } = await jwtVerify(token, JWKS, {
      issuer: ISSUER,
      audience: PROJECT_ID,
    });

    // uid do Firebase costuma estar em payload.user_id (ou payload.sub)
    const uid = payload.user_id || payload.sub || "user";
    const email = payload.email || "";

    // Libera APENAS o methodArn chamado (bem restrito)
    return policy("Allow", event.methodArn, uid, {
      uid: String(uid),
      email: String(email),
      issuer: String(payload.iss || ""),
    });
  } catch (err) {
    console.log("AUTH ERROR:", err?.message || err);
    // API Gateway entende "Unauthorized" e retorna 401
    throw new Error("Unauthorized");
  }
};