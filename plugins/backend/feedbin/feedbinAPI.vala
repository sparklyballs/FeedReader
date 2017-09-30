//	This file is part of FeedReader.
//
//	FeedReader is free software: you can redistribute it and/or modify
//	it under the terms of the GNU General Public License as published by
//	the Free Software Foundation, either version 3 of the License, or
//	(at your option) any later version.
//
//	FeedReader is distributed in the hope that it will be useful,
//	but WITHOUT ANY WARRANTY; without even the implied warranty of
//	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//	GNU General Public License for more details.
//
//	You should have received a copy of the GNU General Public License
//	along with FeedReader.  If not, see <http://www.gnu.org/licenses/>.

public class FeedReader.FeedbinAPI : Object {

	private FeedbinConnection m_connection;
	private FeedbinUtils m_utils;

	public FeedbinAPI()
	{
		m_connection = new FeedbinConnection();
		m_utils = new FeedbinUtils();
	}

	public LoginResponse login()
	{
		Logger.debug("feedbin backend: login");

		if(!Utils.ping("https://api.feedbin.com/"))
			return LoginResponse.NO_CONNECTION;

		var status = m_connection.getRequest("authentication.json").status;
		if(status == 200)
			return LoginResponse.SUCCESS;
		else if(status == 401)
			return LoginResponse.WRONG_LOGIN;

		Logger.error("Got status %u from Feedbin authentication.json".printf(status));
		return LoginResponse.UNKNOWN_ERROR;
	}

	public bool getSubscriptionList(Gee.List<Feed> feeds)
	{
		var response = m_connection.getRequest("subscriptions.json");

		if(response.status != 200)
			return false;

		var parser = new Json.Parser();
		try
		{
			parser.load_from_data(response.data, -1);
		}
		catch (Error e)
		{
			Logger.error("getTagList: Could not load message response");
			Logger.error(e.message);
			return false;
		}
		Json.Array array = parser.get_root().get_array();

		for (int i = 0; i < array.get_length (); i++)
		{
			Json.Object object = array.get_object_element(i);

			string url = object.get_string_member("site_url");
			string id = object.get_int_member("feed_id").to_string();
			string xmlURL = object.get_string_member("feed_url");

			string title = "No Title";
			if(object.has_member("title"))
			{
				title = object.get_string_member("title");
			}
			else
			{
				title = Utils.URLtoFeedName(url);
			}

			feeds.add(
				new Feed(
					id,
					title,
					url,
					0,
					ListUtils.single("0"),
					null,
					xmlURL)
			);
		}

		return true;
	}

	public bool getTaggings(Gee.List<category> categories, Gee.List<Feed> feeds)
	{
		var response = m_connection.getRequest("taggings.json");

		if(response.status != 200)
			return false;

		var parser = new Json.Parser();
		try
		{
			parser.load_from_data(response.data, -1);
		}
		catch (Error e)
		{
			Logger.error("getTagList: Could not load message response");
			Logger.error(e.message);
			return false;
		}
		Json.Array array = parser.get_root().get_array();

		for (int i = 0; i < array.get_length (); i++)
		{
			Json.Object object = array.get_object_element(i);

			string id = "catID%i".printf(i);
			string name = object.get_string_member("name");
			string feedID = object.get_int_member("feed_id").to_string();

			string? id2 = m_utils.catExists(categories, name);

			if(id2 == null)
			{
				categories.add(
					new category (
						id,
						name,
						0,
						i+1,
						CategoryID.MASTER.to_string(),
						1
					)
				);

				m_utils.addFeedToCat(feeds, feedID, id);
			}
			else
			{
				m_utils.addFeedToCat(feeds, feedID, id2);
			}
		}

		return true;
	}

	public Gee.List<Article> getEntries(int page, bool onlyStarred, Gee.Set<string> unreadIDs, Gee.Set<string> starredIDs, DateTime? timestamp, string? feedID = null)
	{
		Gee.List<Article> articles = new Gee.ArrayList<Article>();
		string request = "entries.json?per_page=100";
		request += "&page=%i".printf(page);
		request += "&starred=%s".printf(onlyStarred ? "true" : "false");
		if(timestamp != null)
		{
			var t = GLib.TimeVal();
			if(timestamp.to_timeval(out t))
			{
				request += "&since=%s".printf(t.to_iso8601());
			}
		}

		request += "&include_enclosure=true";

		if(feedID != null)
			request = "feeds/%s/%s".printf(feedID, request);

		Logger.debug(request);

		string response = m_connection.getRequest(request).data;

		var parser = new Json.Parser();
		try
		{
			parser.load_from_data(response, -1);
		}
		catch(Error e)
		{
			Logger.error("getEntries: Could not load message response");
			Logger.error(e.message);
			Logger.error(response);
			return articles;
		}

		var root = parser.get_root();
		if(root.get_node_type() != Json.NodeType.ARRAY)
		{
			Logger.error(response);
			return articles;
		}

		var array = root.get_array();
		uint length = array.get_length();

		Logger.debug("article count: %u".printf(length));

		for(uint i = 0; i < length; i++)
		{
			Json.Object object = array.get_object_element(i);
			string id = object.get_int_member("id").to_string();

			var time = new GLib.DateTime.now_local();

			var t = GLib.TimeVal();
			if(t.from_iso8601(object.get_string_member("published")))
			{
				time = new DateTime.from_timeval_local(t);
			}

			var article = new Article(
					id,
					object.get_string_member("title") == null ? "" : object.get_string_member("title"),
					object.get_string_member("url"),
					object.get_int_member("feed_id").to_string(),
					unreadIDs.contains(id) ? ArticleStatus.UNREAD : ArticleStatus.READ,
					starredIDs.contains(id) ? ArticleStatus.MARKED : ArticleStatus.UNMARKED,
					object.get_string_member("content") == null ? "" : object.get_string_member("content"),
					object.get_string_member("summary"),
					object.get_string_member("author"),
					time,
					-1,
					null,
					null
				);
			if(article != null)
				articles.add(article);
			else
			{
				var node = new Json.Node(Json.NodeType.OBJECT);
				node.set_object(object);
				Logger.error("Failed to create article from " + Json.to_string(node, true));
			}
		}

		return articles;
	}

	public Gee.List<string> unreadEntries()
	{
		string response = m_connection.getRequest("unread_entries.json").data;
		response = response.substring(1, response.length-2);
		return StringUtils.split(response, ",");
	}

	public Gee.List<string> starredEntries()
	{
		string response = m_connection.getRequest("starred_entries.json").data;
		response = response.substring(1, response.length-2);
		return StringUtils.split(response, ",");
	}

	public void createUnreadEntries(Gee.List<string> articleIDs, bool read)
	{
		Json.Array array = new Json.Array();
		foreach(string id in articleIDs)
		{
			array.add_int_element(int64.parse(id));
		}

		Json.Object object = new Json.Object();
		object.set_array_member("unread_entries", array);
		string json = FeedbinUtils.json_object_to_string(object);

		Response res;
		if(!read)
			res = m_connection.postRequest("unread_entries.json", json);
		else
			res = m_connection.postRequest("unread_entries/delete.json", json);
		if(res.status != 200)
			Logger.error("Setting articles %s to %s failed with status %u and response %s".printf(StringUtils.join(articleIDs, ","), read ? "read" : "unread", res.status, res.data));
	}

	public void createStarredEntries(Gee.List<string> articleIDs, bool starred)
	{
		Json.Array array = new Json.Array();
		foreach(string id in articleIDs)
		{
			array.add_int_element(int64.parse(id));
		}

		Json.Object object = new Json.Object();
		object.set_array_member("starred_entries", array);

		string json = FeedbinUtils.json_object_to_string(object);

		if(starred)
			m_connection.postRequest("starred_entries.json", json);
		else
			m_connection.deleteRequest("starred_entries.json", json);
	}

	public void deleteSubscription(string feedID)
	{
		m_connection.deleteRequest("subscriptions/%s.json".printf(feedID));
	}

	public string? addSubscription(string url, out string? error)
	{
		error = null;

		Json.Object object = new Json.Object();
		object.set_string_member("feed_url", url);
		string json = FeedbinUtils.json_object_to_string(object);

	 	var response = m_connection.postRequest("subscriptions.json", json);
		switch(response.status) {
			case 200:
			case 201:
			case 302:
			break;
			case 404:
			error = "No RSS feed found at location %s".printf(url);
			return null;
			case 300:
			// TODO: Parse the JSON response and list the options
			error = "Multiple choices for feeds at location %s".printf(url);
			return null;
			default:
			error = "Unknown error subscribing to feed %s, status = %u".printf(url, response.status);
			return null;
		}

		var location = response.headers.get_one("Location");
		if(location == null) {
			error = "Feedbin API error adding feed %s, no Location header".printf(url);
			return null;
		}
		Logger.info("Location: %s".printf(location));
		return null;
	}

	public void renameFeed(string feedID, string title)
	{
		Json.Object object = new Json.Object();
		object.set_string_member("title", title);
		string json = FeedbinUtils.json_object_to_string(object);

		Logger.debug("Renaming feed %s: %s".printf(feedID, json));
		var response = m_connection.postRequest("subscriptions/%s/update.json".printf(feedID), json);

		Logger.debug("subscriptions/%s/update.json: %s".printf(feedID, response.data));
	}

}
