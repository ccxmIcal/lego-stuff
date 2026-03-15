import mysql.connector
import json
import re

import classes.timeutils as TimeUtils
import classes.datasecurity as Crptography

Cryptography = Crptography.CryptoClass("rouwu")

class MySql():
    def __init__(self, database = None):
        self.connection = None
        self.cursor = None
        self.db = database
    
    def connect(self, hostname: str, username: str, password: str):
        try:
            self.connection = mysql.connector.connect(
                host=hostname,
                user=username,
                passwd=password,
                database = self.db,
                autocommit = True
            )
            self.cursor = self.connection.cursor()
            self.cursor.execute('SET SESSION interactive_timeout=31536000;')
            self.cursor.execute('SET SESSION wait_timeout=31536000;')

        except mysql.connector.Error as err:
            print("Failed to connect to database!", err)

    def isconnected(self, need_db: bool) -> bool:
        if need_db:
            if not self.db:
                print("[ERROR] Not connected to a database!")
                return False
            else:
                return True
        else:
            if self.db:
                print("[ERROR] Connected to a database!")
                return False
            else:
                return True

    def makedatabase(self, database_name: str):
        if not self.isconnected(False):
            return

    def maketable(self, table_name: str, columns: dict) -> bool:
        if not self.isconnected(True):
            return
        
        try:
            columns_str = ", ".join([f"{col} {datatype}" for col, datatype in columns.items()])
            query = f"CREATE TABLE {table_name} ({columns_str})"
            self.cursor.execute(query)
        except Exception as e:
            print(f"[ERROR] Creating table. {e}")
        
    def deletetable(self, table: str):
        if not self.isconnected(True):
            return
        try:
            self.cursor.execute(f"DROP TABLE IF EXISTS {table}")
            self.connection.commit()
        except Exception as e:
            print(f"Error deleting table: {table}. Error: {e}")
            self.connection.rollback()

    def istable(self, table: str):
        if not self.isconnected(True):
            return
        
        self.cursor.execute("SHOW TABLES")
        for x in self.cursor:
            if x[0] == table:
                return True
        
        return False
    
    def user_exists(self, user: int):
        result = self.cursor.execute(f"SELECT * FROM users WHERE user_id = {user}")
        result = self.cursor.fetchall()
        if result is not None:
            return len(result) > 0
        else:
            return False
        
    def get_user(self, user: int):
        result = self.cursor.execute(f"SELECT * FROM users WHERE user_id = {user}")
        result = self.cursor.fetchone()
        return result
    
    def show_tables(self):
        try:
            self.cursor.execute("SELECT name FROM sqlite_master WHERE type='table';")
            tables = [table[0] for table in self.cursor.fetchall()]
            return tables
        except Exception as e:
            print("Error retrieving tables:", e)
            return []

    def show_table_content(self, table_name):
        try:
            self.cursor.execute(f"SELECT * FROM {table_name};")
            rows = self.cursor.fetchall()
            return rows
        except Exception as e:
            print(f"Error retrieving content from table {table_name}: {e}")
            return []
    
    def insert(self, table: str, data: dict):
        try:
            columns = ', '.join(data.keys())
            placeholders = ', '.join(['%s' for _ in data])
            query = f"INSERT INTO {table} ({columns}) VALUES ({placeholders})"
            self.cursor.execute(query, tuple(data.values()))
            self.connection.commit()
            return True
        except Exception as e:
            print(f"Error inserting data into table {table}: {e}")
            self.connection.rollback()
            return False
        
    def removeuser(self, userid: int):
        try:
            self.cursor.execute(f"DELETE FROM users WHERE user_id = {userid}")
            self.connection.commit()
            return True
        except Exception as e:
            print(f"Error removing user: {e}")
            self.connection.rollback()
            return False
        
    def userexpired(self, userid: int):
        self.cursor.execute(f"SELECT expires_at FROM users WHERE user_id = {userid}")
        result = self.cursor.fetchone()
        expires_at = result[0]
        return TimeUtils.TimeUtils.is_expired(expires_at)
    
    def getusers(self):
        self.cursor.execute("SELECT COUNT(*) FROM users")
        result = self.cursor.fetchone()[0]
        return result
    
    def getexpiry(self, userid: int):
        self.cursor.execute(f"SELECT expires_at FROM users WHERE user_id = {userid}")
        result = self.cursor.fetchone()
        expires_at = result[0]
        return expires_at
    
    def adddays(self, userid: int, days: int):
        try:
            self.cursor.execute(f"UPDATE users SET expires_at = {days} WHERE user_id = {userid}")
            self.connection.commit()
            return True
        except Exception as e:
            print(f"Error adding days to user: {e}")
            self.connection.rollback()
            return False
        
    def setapikey(self, userid: int, key: str):
        try:
            key = self.sanitizedstring(key)
            sql = "UPDATE users SET apikey = %s WHERE user_id = %s"
            self.cursor.execute(sql, (key, userid))
            self.connection.commit()
            return True
        except Exception as e:
            print("Error setting the api key:", e)
            self.connection.rollback()
            return False
        
    def guild_exists(self, guildid: int):
        result = self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchall()
        if result is not None:
            return len(result) > 0
        else:
            return False
    
    def remove_guild(self, guildid: int) -> bool:
        try:
            self.cursor.execute(f"DELETE FROM guilds WHERE id = {guildid}")
            self.connection.commit()
            return True
        except Exception as e:
            print(f"Error removing guild: {e}")
            self.connection.rollback()
            return False
        
    def remove_all_guild(self, guildid: int) -> bool:
        try:
            self.cursor.execute(f"DELETE FROM allguilds WHERE id = {guildid}")
            self.connection.commit()
            return True
        except Exception as e:
            print(f"Error removing guild: {e}")
            self.connection.rollback()
            return False
        
    def isguildmaster(self, guildid: int, userid: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            perms = json.loads(result[4])
            if userid in perms["administrators"]:
                return True
            else:
                return False
        else:
            return False
        
    def isguildmod(self, guildid: int, userid: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            perms = json.loads(result[4])
            if userid in perms["rmods"]:
                return True
            else:
                return False
        else:
            return False
        
    def addtolist(self, guildid: int, field: str, newid: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            perms = json.loads(result[4])
            if newid in perms[field]:
                return True
            perms[field].append(newid)

            try:
                self.cursor.execute(f"UPDATE guilds SET perms = '{json.dumps(perms)}' WHERE id = {guildid}")
                self.connection.commit()
                return True
            except Exception as e:
                print(f"Error: {e}")
                self.connection.rollback()
                return False
        else:
            return False
            
    def removefromlist(self, guildid: int, field: str, idtoremove: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            perms = json.loads(result[4])
            if idtoremove in perms[field]:
                perms[field].remove(idtoremove)
                try:
                    self.cursor.execute(f"UPDATE guilds SET perms = '{json.dumps(perms)}' WHERE id = {guildid}")
                    self.connection.commit()
                    return True
                except Exception as e:
                    print(f"Error: {e}")
                    self.connection.rollback()
                    return False
            else:
                return False
        else:
            return False
        
    def setguildperms(self, guildid: int, field: str, newid: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            perms = json.loads(result[4])
            if perms[field] != None:
                perms[field] = newid
                try:
                    self.cursor.execute(f"UPDATE guilds SET perms = '{json.dumps(perms)}' WHERE id = {guildid}")
                    self.connection.commit()
                    return True
                except Exception as e:
                    print(f"Error: {e}")
                    self.connection.rollback()
                    return False
            else:
                return False
        else:
            return False
        
    def setguildapikey(self, guildid: int, apikey: str, universeid: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            try:
                encryptedkey = Cryptography.encrypt(apikey)
                self.cursor.execute(f"UPDATE guilds SET apikey = %s, universeid = %s WHERE id = %s", (encryptedkey, universeid, guildid))
                self.connection.commit()
                return True
            except Exception as e:
                print(f"Error: {e}")
                self.connection.rollback()
                return False
        else:
            return False
        
    def getguildchannel(self, guildid: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            perms = json.loads(result[4])
            return perms["botlogschannel"], perms["modlogschannel"]
        else:
            return 0,0
        
    def getguildkeys(self, guildid: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            encrypted_key = bytes(result[2])
            decrypted_key = Cryptography.decrypt(encrypted_key)
            return decrypted_key, result[3]
        else:
            return 0,0
        
    def getguildconfig(self, guildid: int):
        self.cursor.execute(f"SELECT * FROM guilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        if result:
            return result
        else:
            return False
        
    def sanitizedstring(self, string: str):
        special_characters = {
            "'": "''",
            '"': '\\"',
            '\\': '\\\\'
        }
        
        # First, remove occurrences of %s and %
        string = string.replace('%s', '').replace('%', '')
        
        # Then sanitize the string for other special characters
        sanitized_string = ''.join(special_characters.get(c, c) for c in string)
        
        return sanitized_string

    
    def getallusers(self):
        self.cursor.execute("SELECT * FROM users")
        result = self.cursor.fetchall()
        return result
    
    def sanitize_ip(self, ip: str):
        valid_ip_chars = re.compile(r'[^0-9a-fA-F:.]')
        sanitized_ip = re.sub(valid_ip_chars, "", ip)
        return sanitized_ip
    
    def whitelistip(self, id: int, ip: str):
        self.cursor.execute(f"SELECT * FROM users WHERE user_id = {id}")
        result = self.cursor.fetchone()
        if result:
            apikeydata = json.loads(result[5])
            if len(apikeydata["whitelisted_ips"]) >= 2:
                return 2
            else:
                try:
                    ip = self.sanitize_ip(ip)
                    if len(ip) < 3:
                        return 1
                    ip = ip[:-3]
                    apikeydata["whitelisted_ips"].append(ip)
                    self.cursor.execute(f"UPDATE users SET apikeydata = '{json.dumps(apikeydata)}' WHERE user_id = {id}")
                    self.connection.commit()
                    return 4
                except:
                    self.connection.rollback()
                    return 3
        else:
            return 1
        
    def clearips(self, id: int):
        self.cursor.execute(f"SELECT * FROM users WHERE user_id = {id}")
        result = self.cursor.fetchone()
        apikeydata = json.loads(result[5])
        try:
            apikeydata["whitelisted_ips"].clear()
            self.cursor.execute(f"UPDATE users SET apikeydata = '{json.dumps(apikeydata)}' WHERE user_id = {id}")
            self.connection.commit()
            return True
        except:
            self.connection.rollback()
            return False
        
    def getallstatsguilds(self):
        self.cursor.execute("SELECT * FROM allguilds")
        return self.cursor.fetchall()
    
    def setguildstats(self, guildid: int, place_id: int, stats_category: int):
        self.cursor.execute(f"SELECT * FROM allguilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        wanted_data = json.loads(result[1])
        try:
            wanted_data['stats_category'] = stats_category
            wanted_data['place_id'] = place_id
            self.cursor.execute(f"UPDATE allguilds SET stats = '{json.dumps(wanted_data)}' WHERE id = {guildid}")
            self.connection.commit()
            return True
        except:
            self.connection.rollback()
            return False
        
    def setguildchannels(self, guildid: int, channels: dict):
        self.cursor.execute(f"SELECT * FROM allguilds WHERE id = {guildid}")
        result = self.cursor.fetchone()
        wanted_data = json.loads(result[1])
        try:
            wanted_data["channels"] = channels
            self.cursor.execute(f"UPDATE allguilds SET stats = '{json.dumps(wanted_data)}' WHERE id = {guildid}")
            self.connection.commit()
            return True
        except:
            self.connection.rollback()
            return False
