<%@ WebHandler Language="C#" Class="WellDunne.WebTools.TFSashx" %>
<%-- NOTE(jsd): Change these to Version=10.0.0.0 or Version=9.0.0.0, depending on your installed TFS version. --%>
<%@ Assembly Name="Microsoft.TeamFoundation.Client, Version=11.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" %>
<%@ Assembly Name="Microsoft.TeamFoundation.VersionControl.Client, Version=11.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" %>
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Web;
using Microsoft.TeamFoundation.Client;
using Microsoft.TeamFoundation.VersionControl.Client;

namespace WellDunne.WebTools
{
    /// <summary>
    /// Simple handler to fetch items from TFS version control. Requires TFS API assemblies GACed or copied to bin/ folder.
    /// </summary>
    public class TFSashx : IHttpHandler
    {
        /// <summary>
        /// Static URL to the TFS server to use.
        /// </summary>
        static readonly Uri tfsUri = new Uri(@"http://your.local.tfs.here:8080/tfs");
        static Microsoft.TeamFoundation.Client.TfsTeamProjectCollection tpc = new Microsoft.TeamFoundation.Client.TfsTeamProjectCollection(tfsUri);
        static VersionControlServer vcs = tpc.GetService<VersionControlServer>();

        public bool IsReusable { get { return true; } }

        class HandlerHttpResponse
        {
            public readonly int StatusCode;
            public readonly string StatusDescription;
            public readonly Action<HttpResponse> WriteBody;

            public HandlerHttpResponse(int statusCode, string statusDescription, Action<HttpResponse> writeBody)
            {
                this.StatusCode = statusCode;
                this.StatusDescription = statusDescription;
                this.WriteBody = writeBody;
            }

            public HandlerHttpResponse(int statusCode, string statusDescription)
                : this(statusCode, statusDescription, emptyBody)
            {
            }

            static void emptyBody(HttpResponse rsp)
            {
                rsp.ContentType = "text/plain";
            }
        }

        public void ProcessRequest(HttpContext context)
        {
            var req = context.Request;

            HandlerHttpResponse hr;
            try
            {
                hr = Process(req);
            }
            catch (Exception ex)
            {
                hr = new HandlerHttpResponse(500, ex.Message, r => r.Output.Write(ex.ToString()));
            }

            var rsp = context.Response;
            rsp.TrySkipIisCustomErrors = true;
            rsp.StatusCode = hr.StatusCode;
            rsp.StatusDescription = hr.StatusDescription;
            hr.WriteBody(rsp);
        }

        HandlerHttpResponse Process(HttpRequest req)
        {
#if false
            // For debugging purpose:
            string ashxUrl = req.AppRelativeCurrentExecutionFilePath.Substring(1);
            if (req.ApplicationPath != "/") ashxUrl = req.ApplicationPath + ashxUrl;

            return new HandlerHttpResponse(200, "OK", rsp =>
            {
                rsp.Output.WriteLine(ashxUrl);
                rsp.Output.WriteLine(Uri.UnescapeDataString(req.Url.AbsolutePath));
            });
#endif

            // Find out how many chars to skip at the start of the URL's path to find the remainder path:
            int skipChars = req.AppRelativeCurrentExecutionFilePath.Length - 1;
            if (req.ApplicationPath != "/") skipChars += req.ApplicationPath.Length;

            // Get the unenscaped remainder path after `~/tfs.ashx`:
            string urlRemainder = Uri.UnescapeDataString(req.Url.AbsolutePath);
            if (skipChars + 1 > urlRemainder.Length) return new HandlerHttpResponse(400, "No path specified");

            urlRemainder = urlRemainder.Substring(skipChars + 1);
            if (String.IsNullOrEmpty(urlRemainder)) return new HandlerHttpResponse(400, "No path specified");

            // Turn the absolute path into a TFS path:
            string path = urlRemainder;
            if (!path.StartsWith("$/")) path = "$/" + path;

#if false
            // Connect to TFS:
            var tpc = new Microsoft.TeamFoundation.Client.TfsTeamProjectCollection(tfsUri);
            var vcs = tpc.GetService<VersionControlServer>();
#endif

            // Find the item in TFS:
            var itemSet = vcs.GetItems(new ItemSpec(path, RecursionType.None), VersionSpec.Latest, DeletedState.NonDeleted, ItemType.Any, GetItemsOptions.Download | GetItemsOptions.Unsorted);
            if (itemSet.Items.Length == 0)
                return new HandlerHttpResponse(404, "Not found");

            var item = itemSet.Items[0];
            System.Diagnostics.Debug.Assert(item != null);

            if (item.ItemType != ItemType.File)
                return new HandlerHttpResponse(400, "Requested item is not a file");

            // Calculate the ETag of the item:
            string itemetag = String.Concat("\"", Convert.ToBase64String(item.HashValue), "\"");

            // See if the client has an ETag to check:
            string reqetag;
            if ((reqetag = req.Headers["If-None-Match"]) != null)
            {
                if (itemetag == reqetag)
                    return new HandlerHttpResponse(304, "Not modified");
            }

            // Return a response that copies the file from TFS:
            return new HandlerHttpResponse(200, "OK", rsp =>
            {
                rsp.Cache.SetCacheability(HttpCacheability.Public);
                rsp.Cache.SetETag(itemetag);
                rsp.Cache.SetLastModified(item.CheckinDate);
                rsp.Cache.SetMaxAge(TimeSpan.FromHours(1));

                rsp.Buffer = false;
                rsp.AppendHeader("Content-Length", item.ContentLength.ToString());
                if (item.Encoding == -1)
                {
                    // Binary content:
                    rsp.ContentType = "application/octet-stream";
                }
                else
                {
                    // Text content with a codepage for encoding:
                    var enc = System.Text.Encoding.GetEncoding(item.Encoding);
                    rsp.ContentType = "text/plain; charset=" + enc.WebName;
                }

                // Copy the file to the response:
                using (var stream = item.DownloadFile())
                using (rsp.OutputStream)
                    CopyStream(stream, rsp.OutputStream);
            });
        }

        static void CopyStream(Stream read, Stream write)
        {
            const int bufferSize = 4096;
            byte[] buf = new byte[bufferSize];

            int nr;
            while ((nr = read.Read(buf, 0, bufferSize)) > 0)
            {
                write.Write(buf, 0, nr);
                write.Flush();
            }
        }
    }
}