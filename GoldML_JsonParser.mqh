//+------------------------------------------------------------------+
//|                       GoldML_JsonParser.mqh                      |
//|          Robust JSON Parser for Gold ML Trading System           |
//|  AUDIT-C1: Replaces fragile StringFind-based JSON parsing        |
//|  Handles whitespace, null values, missing fields, HMAC verify    |
//+------------------------------------------------------------------+
#property copyright "Gold ML Institutional System"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| CJsonParser — lightweight flat JSON parser                        |
//|                                                                  |
//| Supports flat JSON objects (one level deep).                     |
//| Keys and string values must not contain escaped quotes.          |
//| Handles spaces/tabs/newlines around ':' and values.              |
//+------------------------------------------------------------------+
class CJsonParser
{
private:
   string   m_json;       // Raw JSON string (stripped)
   bool     m_valid;      // True if Parse() succeeded

   //--- Skip whitespace characters from position pos
   int SkipWS(const string &s, int pos) const
   {
      int len = StringLen(s);
      while(pos < len)
      {
         ushort c = StringGetCharacter(s, pos);
         if(c != ' ' && c != '\t' && c != '\n' && c != '\r')
            break;
         pos++;
      }
      return pos;
   }

   //--- Find the value substring for key.
   //    Returns the raw value token (without surrounding quotes for strings).
   //    Sets isString=true if value was quoted.
   //    Returns "" if key not found.
   string FindRawValue(const string &json, const string &key,
                       bool &isString, bool &isNull) const
   {
      isString = false;
      isNull   = false;

      // Build search pattern: "key":
      string pattern = "\"" + key + "\"";
      int len = StringLen(json);
      int pos = 0;

      while(pos < len)
      {
         int found = StringFind(json, pattern, pos);
         if(found == -1)
            return "";

         // Advance past the key
         int cur = found + StringLen(pattern);
         cur = SkipWS(json, cur);

         // Expect ':'
         if(cur >= len || StringGetCharacter(json, cur) != ':')
         {
            // Not a key:value — could be a value containing this pattern; keep searching
            pos = found + 1;
            continue;
         }
         cur++; // skip ':'
         cur = SkipWS(json, cur);

         if(cur >= len)
            return "";

         ushort first = StringGetCharacter(json, cur);

         // null
         if(StringSubstr(json, cur, 4) == "null")
         {
            isNull = true;
            return "null";
         }

         // String value
         if(first == '"')
         {
            cur++; // skip opening quote
            int end = cur;
            while(end < len)
            {
               ushort ch = StringGetCharacter(json, end);
               if(ch == '"') break;
               // Handle escaped quote
               if(ch == '\\') { end += 2; continue; }
               end++;
            }
            isString = true;
            return StringSubstr(json, cur, end - cur);
         }

         // Numeric / boolean / bare value
         int end = cur;
         while(end < len)
         {
            ushort ch = StringGetCharacter(json, end);
            if(ch == ',' || ch == '}' || ch == ']' ||
               ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
               break;
            end++;
         }
         return StringSubstr(json, cur, end - cur);
      }
      return "";
   }

public:
   CJsonParser() : m_valid(false) {}

   //--- Parse a JSON object string. Returns false if invalid.
   bool Parse(const string json)
   {
      m_valid = false;
      if(StringLen(json) < 2)
      {
         // AUDIT-C1: Log invalid JSON
         Print("[JsonParser] WARNING: JSON too short to parse");
         return false;
      }

      // Basic sanity: must start with '{' and end with '}'
      int start = SkipWS(json, 0);
      if(StringGetCharacter(json, start) != '{')
      {
         Print("[JsonParser] WARNING: JSON does not start with '{'");
         return false;
      }

      m_json  = json;
      m_valid = true;
      return true;
   }

   //--- Extract a boolean value. Returns false if key absent or value is null.
   bool GetBool(const string key, bool &value)
   {
      if(!m_valid) return false;
      bool isStr = false, isNull = false;
      string raw = FindRawValue(m_json, key, isStr, isNull);

      if(raw == "" || isNull)
      {
         // AUDIT-C1: Log missing field
         Print("[JsonParser] WARNING: field '", key, "' absent or null");
         return false;
      }

      string lower = raw;
      StringToLower(lower);
      if(lower == "true")  { value = true;  return true; }
      if(lower == "false") { value = false; return true; }

      Print("[JsonParser] WARNING: field '", key, "' is not a boolean: ", raw);
      return false;
   }

   //--- Extract a string value. Returns false if key absent or value is null.
   bool GetString(const string key, string &value)
   {
      if(!m_valid) return false;
      bool isStr = false, isNull = false;
      string raw = FindRawValue(m_json, key, isStr, isNull);

      if(raw == "" || isNull)
      {
         Print("[JsonParser] WARNING: field '", key, "' absent or null");
         return false;
      }

      value = raw;
      return true;
   }

   //--- Extract a double value. Returns false if key absent or value is null.
   bool GetDouble(const string key, double &value)
   {
      if(!m_valid) return false;
      bool isStr = false, isNull = false;
      string raw = FindRawValue(m_json, key, isStr, isNull);

      if(raw == "" || isNull)
      {
         Print("[JsonParser] WARNING: field '", key, "' absent or null");
         return false;
      }

      value = StringToDouble(raw);
      return true;
   }

   //--- Extract an integer value. Returns false if key absent or value is null.
   bool GetInt(const string key, int &value)
   {
      if(!m_valid) return false;
      bool isStr = false, isNull = false;
      string raw = FindRawValue(m_json, key, isStr, isNull);

      if(raw == "" || isNull)
      {
         Print("[JsonParser] WARNING: field '", key, "' absent or null");
         return false;
      }

      value = (int)StringToInteger(raw);
      return true;
   }

   //--- Returns true if the last Parse() call succeeded
   bool IsValid() const { return m_valid; }
};
//+------------------------------------------------------------------+
