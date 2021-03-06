# encoding: utf-8

=begin
   Copyright 2016 Telegraph-ai

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
=end

require_relative '../navigation.rb'

module Giskard
	module FB
		class Messenger < Grape::API
			prefix FB_WEBHOOK_PREFIX.to_sym
			format :json

			def self.send(payload,type="messages",file_url=nil)
				Bot.log.debug "sending payload via #{type} :"
				Bot.log.debug payload
				begin
					if file_url.nil? then
						res = RestClient.post "https://graph.facebook.com/v2.6/me/#{type}?access_token=#{FB_PAGEACCTOKEN}", payload.to_json, :content_type => :json
					else # image upload 
						params={"recipient"=>payload['recipient'], "message"=>payload['message'], "filedata"=>File.new(file_url,'rb'),"multipart"=>true}
						res = RestClient.post "https://graph.facebook.com/v2.6/me/#{type}?access_token=#{FB_PAGEACCTOKEN}",params
					end
					Bot.log.debug "sending done (code: #{res.code})"
				rescue RestClient::BadRequest=>e
					Bot.log.error "BAD Request : #{e}"
					#Bot.log.error "#{payload}"
					raise e
				end
			end

			def self.init
				payload={
					"greeting"=>[{
						"locale"=>"default",
						"text"=>"Bonjour {{user_first_name}}, merci pour votre intérêt pour le jugement majoritaire ! Cliquez sur Démarrer (en bas de page) pour commencer l'expérimentation." 
					}]
				}
				Giskard::FB::Messenger.send(payload,"messenger_profile")
			end

			helpers do
				def authorized # Used for API calls and to verify webhook
					headers['Secret-Key']==FB_SECRET
				end

				def send_msg(id,text,kbd=nil,attachment=nil)
					msg={
						"recipient"=>{"id"=>id},
						"message"=>{}
					}
					msg["message"].merge!({"text"=>text}) if not text.nil?
					if not kbd.nil?
						msg["message"].merge!({"quick_replies"=>[]})
						kbd.each do |k|
							title=k['title'].nil? ? k['text'] : k['title']
							payload=k['payload'].nil? ? k['text'] : k['payload']
							image_url=k['image_url'].nil? ? nil : k['image_url']
							qr={
								"content_type"=>"text",
								"title"=>title,
								"payload"=>payload
							}
							qr["image_url"]=image_url unless image_url.nil?
							msg["message"]["quick_replies"].push(qr)
						end
					end
					msg["message"].merge!({ "attachment"=>attachment }) if not attachment.nil?
					msg.delete("message") if msg["message"].empty?
					Giskard::FB::Messenger.send(msg)
				end

				def send_typing(id)
					Giskard::FB::Messenger.send({"recipient"=>{"id"=>id},"sender_action"=>"typing_on"})
				end

				def send_image(id,img_url)
					payload={"recipient"=>{"id"=>id},"message"=>{"attachment"=>{"type"=>"image","payload"=>{}}}}
					if not img_url.match(/http/).nil? then
						payload["message"]["attachment"]["payload"]={"url"=>img_url}
						Giskard::FB::Messenger.send(payload)
					else
						Giskard::FB::Messenger.send(payload,"messages",img_url)
					end
				end

				def process_msg(id,msg,options)
					lines=msg.split("\n")
					buffer=""
					max=lines.length
					idx=0
					image=false
					kbd=nil
					attachment=nil
					lines.each do |l|
						next if l.empty?
						idx+=1
						image=(l.start_with?("image:") && (['.jpg','.png','.gif','.jpeg'].include? File.extname(l)))
						has_attachment=l.start_with?("attachment:")
						if image && !buffer.empty? then # flush buffer before sending image
							writing_time=buffer.length/TYPINGSPEED
							send_typing(id)
							sleep(writing_time)
							send_msg(id,buffer)
							buffer=""
						end
						if image then # sending image
							send_typing(id)
							send_image(id,l.split(":",2)[1])
						else # sending 1 msg for every line
							writing_time=l.length/TYPINGSPEED
							writing_time=l.length/TYPINGSPEED_SLOW if max>1
							send_typing(id)
							sleep(writing_time)
							if l.start_with?("no_preview:") then
								l=l.split(':',2)[1]
							end
							if (idx==max) then
								kbd=options[:kbd] 
							end
							attachment=options[:attachments].shift() if has_attachment
							Bot.log.info "l=#{l} attachment=#{has_attachment}"
							if not has_attachment then
								send_msg(id,l,kbd,nil)
							else
								send_msg(id,nil,nil,attachment)
							end
						end
					end
				end
			end

			# challenge for creating a webhook
			get '/fbmessenger' do
				if params['hub.verify_token']==FB_SECRET then
					return params['hub.challenge'].to_i
				else
					return "nope"
				end
			end

			# we receive a new message
			post '/fbmessenger' do
				object 	    = params['object']
				if object=='page' then
					entries     = params['entry']
					entries.each do |entry|
						entry.messaging.each do |messaging|
							Bot.log.debug "#{messaging}"
							msg 	 = Giskard::FB::Message.new(messaging)
							user     = Giskard::FB::User.new(messaging.sender.id)
							user.create unless user.load
							if not user.already_answered?(msg) and not msg.nil? then
								screen        = Bot.nav.get(msg, user)
								process_msg(user.id,screen[:text],screen) unless screen[:text].nil?
							end
							user.save
							user = nil
							msg = nil
						end
					end   
				elsif object=='api' then # api call / not from messenger
					cmd=params['cmd']
					token=params['token']
					uid=params['uid']
					return if cmd.nil? or cmd.empty?
					return if token.nil? or token.empty?
					decoded_token=JWT.decode token, CC_SECRET_FB, true, {:algorithm=> 'HS256'}
					data=decoded_token[0]
					msg = Giskard::FB::Message.new(cmd)
					user     = Giskard::FB::User.new(uid)
					user.id  = data["email"].split('@')[0].to_i
					screen = Bot.nav.get(msg, user)
					process_msg(user.id,screen[:text],screen) unless screen[:text].nil?
				end
			end # post
		end # class
	end # module FB
end # module Bot
