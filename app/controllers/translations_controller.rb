# Copyright 2014 Square Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# Controller for working with Translations. The `TranslationWorkbench` JavaScript
# uses these endpoints to modify, approve, and reject Translations.

class TranslationsController < ApplicationController
  include TranslationDecoration

  before_filter :authenticate_user!
  before_filter :translator_required, only: [:edit, :update]

  before_filter :find_project
  before_filter :find_key
  before_filter :find_translation
  before_filter :find_issues, only: [:show, :edit]

  respond_to :html, except: [:match, :fuzzy_match]
  respond_to :json, only: [:show, :match, :fuzzy_match]

  # Displays a large-format translation view page.
  #
  # Routes
  # ------
  #
  # * `PATCH /projects/:project_id/keys/:key_id/translations/:id`
  #
  # Path Parameters
  # ---------------
  #
  # |              |                                    |
  # |:-------------|:-----------------------------------|
  # | `project_id` | The slug of a Project.             |
  # | `key_id`     | The slug of a Key in that project. |
  # | `id`         | The ID of a Translation.           |

  def show
    respond_with(@translation, location: project_key_translation_url(@project, @key, @translation)) do |format|
      format.json { render json: decorate([@translation]).first }
    end
  end

  # Displays a large-format translation edit page.
  #
  # Routes
  # ------
  #
  # * `PATCH /projects/:project_id/keys/:key_id/translations/:id/edit`
  #
  # Path Parameters
  # ---------------
  #
  # |              |                                    |
  # |:-------------|:-----------------------------------|
  # | `project_id` | The slug of a Project.             |
  # | `key_id`     | The slug of a Key in that project. |
  # | `id`         | The ID of a Translation.           |

  def edit
    respond_with @translation, location: project_key_translation_url(@project, @key, @translation)
  end

  # Updates a Translation with new translated copy. If the translated copy is
  # blank, the translation will be considered to have been "erased" (marked as
  # untranslated) unless the `blank_string` parameter is set.
  #
  # Routes
  # ------
  #
  # * `PATCH /projects/:project_id/keys/:key_id/translations/:id`
  #
  # Path Parameters
  # ---------------
  #
  # |              |                                    |
  # |:-------------|:-----------------------------------|
  # | `project_id` | The slug of a Project.             |
  # | `key_id`     | The slug of a Key in that project. |
  # | `id`         | The ID of a Translation.           |
  #
  # Body Parameters
  # ---------------
  #
  # |               |                                               |
  # |:--------------|:----------------------------------------------|
  # | `translation` | Parameterized hash of Translation attributes. |
  #
  # Query Parameters
  # ----------------
  #
  # |                |                                              |
  # |:---------------|:---------------------------------------------|
  # | `blank_string` | If true, a blank translated copy is allowed. |

  def update
    # translators cannot modify approved copy
    return head(:forbidden) if @translation.approved? && current_user.role == 'translator'

    # Need to save true copy_was because assign_attributes will push back the cache
    @translation.freeze_tracked_attributes
    @translation.assign_attributes translation_params

    @translation.translator = current_user if @translation.copy_was != @translation.copy
    @translation.modifier = current_user

    # de-translate translation if empty
    unless params[:blank_string].parse_bool
      @translation.copy = nil if @translation.copy.blank?
      if @translation.copy.nil?
        @translation.translator = nil
        @translation.approved = nil
        @translation.reviewer = nil
      end
    end

    # the only thing that can be edited is copy, so optimize DB calls if this
    # is not a copy edit
    if @translation.copy_was != @translation.copy # copy_changed? can be true even if the copy wasn't changed...
      @translation.preserve_reviewed_status = current_user.reviewer?
      @translation.save
    else
      # if the current user is a reviewer, treat this as an approve action; this
      # makes tabbing through fields act as approval in the front-end
      if current_user.reviewer?
        @translation.reviewer = current_user
        @translation.approved = true
        @translation.preserve_reviewed_status = true
        @translation.save
      end
    end

    respond_with(@translation, location: project_key_translation_url(@project, @key, @translation)) do |format|
      format.json do
        if @translation.valid?
          render json: decorate([@translation]).first
        else
          render json: @translation.errors.full_messages, status: :unprocessable_entity
        end
      end
      format.html do
        if @translation.errors.any?
          redirect_to edit_project_key_translation_url(@project, @key, @translation), flash: { alert: @translation.errors.full_messages.unshift(t('controllers.translations.update.failure')) }
        else
          redirect_to edit_project_key_translation_url(@project, @key, @translation), flash: { success: t('controllers.translations.update.success') }
        end
      end
    end
  end

  # Marks a Translation as approved and records the reviewer as the current
  # User.
  #
  # Routes
  # ------
  #
  # * `PUT /projects/:project_id/keys/:key_id/translations/:id/approve`
  #
  # Path Parameters
  # ---------------
  #
  # |              |                                    |
  # |:-------------|:-----------------------------------|
  # | `project_id` | The slug of a Project.             |
  # | `key_id`     | The Slug of a Key in that project. |
  # | `id`         | The ID of a Translation.           |

  def approve
    @translation.freeze_tracked_attributes
    @translation.approved = true
    @translation.reviewer = current_user
    @translation.modifier = current_user
    @translation.save

    respond_with(@translation, location: project_key_translation_url(@project, @key, @translation)) do |format|
      format.json { render json: decorate([@translation]).first }
    end
  end

  # Marks a Translation as rejected and records the reviewer as the current
  # User.
  #
  # Routes
  # ------
  #
  # * `PUT /projects/:project_id/keys/:key_id/translations/:id/reject`
  #
  # Path Parameters
  # ---------------
  #
  # |              |                                    |
  # |:-------------|:-----------------------------------|
  # | `project_id` | The slug of a Project.             |
  # | `key_id`     | The slug of a Key in that project. |
  # | `id`         | The ID of a Translation.           |

  def reject
    @translation.freeze_tracked_attributes
    @translation.approved = false
    @translation.reviewer = current_user
    @translation.modifier = current_user
    @translation.save

    respond_with(@translation, location: project_key_translation_url(@project, @key, @translation)) do |format|
      format.json { render json: decorate([@translation]).first, location: project_key_translation_url(@project, @key, @translation) }
    end
  end

  # Returns the first eligible Translation Unit that meets the following
  # requirements:
  #
  # * in the same locale,
  # * and has the same source copy.
  #
  # If multiple Translation Units match, priority is given to the most recently
  # updated Translation. If no Translation Units match in the same locale,
  # {Locale#fallbacks fallback} locales are tried in order. Under each
  # fallback locale, a Translation Unit is located that shares the same project, same
  # key, and same source copy. If no match is found, that same fallback locale
  # is searched for a Translation Unit with the same source copy, priority given to
  # the most recently modified Translation. If no match is found, the next more
  # general fallback locale is attempted.
  #
  # In all cases, the candidate Translation must be approved to match.
  #
  # Routes
  # ------
  #
  # * `GET /projects/:project_id/keys/:key_id/translations/:id/match`
  #
  # Path Parameters
  # ---------------
  #
  # |              |                                    |
  # |:-------------|:-----------------------------------|
  # | `project_id` | The slug of a Project.             |
  # | `key_id`     | The slug of a Key in that project. |
  # | `id`         | The ID of a Translation.           |
  #
  # Response
  # ========
  #
  # Returns 204 Not Content and an empty body if no match is found.

  def match
    @translation.locale.fallbacks.each do |fallback|
      @match = TranslationUnit.exact_matches(@translation, fallback).
          order('created_at DESC').first
      break if @match
    end

    return head(:no_content) unless @match
    respond_with @match, location: project_key_translation_url(@project, @key, @translation)
  end

  #TODO return all matches, show popup

  # Returns up to 5 best fuzzy matching Translations that meets the following
  # requirements:
  #
  # * in the same locale,
  #
  # If multiple Translations match, priority is given to the most closely
  # matching Translations.
  #
  # Routes
  # ------
  #
  # * `GET /projects/:project_id/keys/:key_id/translations/:id/fuzzy_match`
  #
  # Path Parameters
  # ---------------
  #
  # |              |                                    |
  # |:-------------|:-----------------------------------|
  # | `project_id` | The slug of a Project.             |
  # | `key_id`     | The slug of a Key in that project. |
  # | `id`         | The ID of a Translation.           |
  #

  def fuzzy_match
    respond_to do |format|
      format.json do
        limit = 5
        query_filter = @translation.source_copy
        target_locale = @translation.rfc5646_locale
        @results = Translation.search(load: { include: { key: :project } }) do
          # TODO: Remove duplicate where source_copy, copy are same
          filter :and,
                 { term: { rfc5646_locale: target_locale } },
                 { not: { missing: { field: 'copy' } } }

          size limit
          query { match 'source_copy', query_filter, operator: 'or' }
        end
        render json: decorate_fuzzy_match(@results, query_filter).to_json
      end
    end
  end

  private

  def find_project
    @project = Project.find_from_slug!(params[:project_id])
  end

  def find_key
    @key = @project.keys.find_by_id!(params[:key_id])
  end

  def find_translation
    @translation = @key.translations.where(rfc5646_locale: params[:id]).first!
  end

  def find_issues
    @issues = @translation.issues.includes(:user, comments: :user).order_default
    @issue = Issue.new_with_defaults
  end

  def translation_params
    params.require(:translation).permit(:copy, :notes)
  end

  def decorate_fuzzy_match(translations, source_copy)
    translations = translations.map do |translation|
      {
          source_copy: translation.source_copy,
          copy: translation.copy,
          match_percentage: source_copy.similar(translation.source_copy)
      }
    end.reject { |t| t[:match_percentage] < 70 }
    translations.sort! { |a, b| b[:match_percentage] <=> a[:match_percentage] }
  end
end
