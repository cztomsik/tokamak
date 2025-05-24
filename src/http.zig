const client = @import("http/client.zig");
const mock = @import("http/mock.zig");

pub const Client = client.Client;
pub const ClientConfig = client.Config;
pub const ClientReqOptions = client.ReqOptions;
pub const ClientReqBody = client.ReqBody;
pub const ClientResponse = client.Response;

pub const MockClient = mock.Client;
